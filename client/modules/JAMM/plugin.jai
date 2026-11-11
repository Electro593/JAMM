#scope_export

Plugin :: struct {
	#as using base: Metaprogram_Plugin;

	stage: enum {
		UNINITIALIZED;
		INITIALIZED;
		PREPARED;
		EXECUTING;
		FINISHED;
		SHUTDOWN;
	} = .UNINITIALIZED;

	options: Options;

	initial_working_directory: string;
    store_modules_path: string;

	modules: Table(*Message_Import, Module);
}

get_plugin :: () -> *Plugin {
	plugin := New(Plugin);

	plugin.init               = init;
	plugin.before_intercept   = before_intercept;
	plugin.add_source         = add_source;
	plugin.message            = message;
	plugin.finish             = finish;
	plugin.shutdown           = shutdown;
	plugin.log_help           = log_help;
	plugin.communication_proc = communication_proc;

	plugin.initial_working_directory = get_normalized_cwd();

	return plugin;
}

// You can use this instead of the plugin CLI or manual configuration. However,
// if you want to do anything fancy, you should make an actual plugin interop.
//
// FUTURE: This is kinda gross. I'd like to get rid of it or replace it with
// something more elegant.
run_plugin :: (
	plugin_options: [] string = .[],
	before_intercept_callback: (plugin: *Plugin, flags: *Intercept_Flags, data: T) = null,
	add_source_callback: (plugin: *Plugin, data: T) = null,
	data: $T = T.{},
	loc := #caller_location
) -> bool {
	plugin := get_plugin();

	workspace := compiler_create_workspace("JAMM Default Workspace");
	plugin.workspace = workspace;
	if !plugin.init(plugin, plugin_options) return false;

	options := get_build_options(workspace);
	options.output_type = .NO_OUTPUT;
	options.write_added_strings = false;
	set_build_options(options, workspace, loc = loc);

	flags: Intercept_Flags;
	plugin.before_intercept(plugin, *flags);
	if before_intercept_callback
		before_intercept_callback(plugin, *flags, data);

	compiler_begin_intercept(workspace, flags);

	plugin.add_source(plugin);
	if add_source_callback
		add_source_callback(plugin, data);

	while true {
		message := compiler_wait_for_message();
		plugin.message(plugin, message);
		if message.kind == .COMPLETE break;
	}

	compiler_end_intercept(workspace);
	plugin.finish(plugin);
	plugin.shutdown(plugin);

	return true;
}

#scope_file

init :: (p: *Metaprogram_Plugin, options: [] string) -> bool {
	plugin: *Plugin = xx p;
	assert(plugin.stage == .UNINITIALIZED);

    if !begins_with(options[0], "-") {
		log_error("Invalid JAMM options %: Options must start with a hyphen.\n", options);
        log_error(HELP_STRING);
        return false;
    }

	option_start := 0;
    cursor := 1;
	while cursor <= options.count {
        it: string;
        defer cursor += 1;

        // This technically breaks if they pass a value which begins with a
        // hyphen, but... just don't? Module names, vendor names, paths and
        // URIs *really* shouldn't be starting with a hyphen, and you can
        // always roll a custom plugin interop if truly necessary.

        if cursor < options.count {
            it = options[cursor];
            if !begins_with(it, "-") continue;
        }

        original_parts := array_view(options, option_start, cursor - option_start);
        parts := array_copy(original_parts,, temp);
        advance(*parts[0], 1);

        option_start = cursor;
        key_parts := parts;
        value := "";

        // HACK: I would much rather the vendor/module be passed as the value,
        // but imposing escape semantics on the value just to delimit them
        // sounds like a pain.
        if parts.count > 1 && parts[0] != "publish" {
            key_parts.count -= 1;
            value = parts[parts.count - 1];
        }

        key := make_option_key(..key_parts);
        success, message := apply_option(*plugin.options, key, value);
        if !success {
            log_error("Invalid JAMM options: Options %, parsed as '%'='%', %.\n", original_parts, key, value, message);
            log_error(HELP_STRING);
            return false;
        }
	}

	plugin.stage = .INITIALIZED;
	return true;
}

before_intercept :: (p: *Metaprogram_Plugin, flags: *Intercept_Flags) {
	plugin: *Plugin = xx p;
	assert(plugin.stage == .INITIALIZED);

	if plugin.options.print_help {
		log(HELP_STRING);
		exit(0);
	}

	// Normalize the store path, and create it if it doesn't exist.
    success, store_modules_path, message := initialize_store(
        plugin.options.store,
        plugin.initial_working_directory
    );
    plugin.store_modules_path = store_modules_path;
    if !success {
        log_error("Failed to initialize module store: '%' %.\n", store_modules_path, message);
        exit(1);
    }

	// TODO: Move the other validation here too

	default_host, added := find_or_add(*plugin.options.host_map, .{});
	if added then default_host.* = get_default_host_path();
	if !default_host.*
		log("Could not determine the default registry host URI. We will abort if anything needs it.");

	for * plugin.options.host_map
		if !it then it.* = copy_string(default_host.*);

	removed, default_key_ref := table_remove(*plugin.options.ssh_map, "");
	default_ssh_host := get_default_host_path();
	default_ssh:, added = find_or_add(*plugin.options.ssh_map, default_ssh_host);
	if !added free(default_ssh_host);
	else default_ssh.* = default_key_ref;

	if !plugin.options.compatibility.do_not_skip_expressions
		flags.* |= .SKIP_ALL;

	if plugin.options.publish.count > 0
		flags.* &= ~.SKIP_DECLARATIONS;

	plugin.stage = .PREPARED;
}

add_source :: (p: *Metaprogram_Plugin) {
	plugin: *Plugin = xx p;
	assert(plugin.stage == .PREPARED);

	add_build_string("__JAMM__ :: 0;", p.workspace, cast(*Message) null);

	plugin.stage = .EXECUTING;
}

message :: (p: *Metaprogram_Plugin, message: *Message) {
	plugin: *Plugin = xx p;
	assert(plugin.stage == .EXECUTING);

	if message.kind == {
	case .FAILED_IMPORT;
		failed_import: *Message_Failed_Import = xx message;
		if failed_import.status != .NOT_FOUND return;

		target_name := failed_import.target_module_name;
		if !begins_with_nocase(target_name, "jamm:") return;
		base_uri := advance(target_name, "jamm:".count);
		print("%\n", failed_import.*);

		// TODO: Remap the import here
		// TODO: Consider: adding a note to the import with the full version + build metadata

		// provide_import(plugin.workspace, failed_import, , );

	case .IMPORT;
		import: *Message_Import = xx message;
		table_set(*plugin.modules, import, .{});

		// TODO: Check that we're not importing anything other than JAMM imports or builtin modules

	case .FILE;
		file: *Message_File = xx message;

		import := file.enclosing_import;
		if !import return;

		module := table_find_pointer(*plugin.modules, import);
		if !module return;

		if import.module_type == {
		case .FILE;
			if file.fully_pathed_filename == import.fully_pathed_filename {
				module.file = file;
				add_build_string("__JAMM__ :: 0;", plugin.workspace, file);
			}
		}

	case .TYPECHECKED;
		typechecked: *Message_Typechecked = xx message;
		for typechecked.declarations {
			decl := it.expression;
			is_declaration := decl.name == "__JAMM_DECLARATION__";
			for decl.notes
				is_declaration |= it.text == "__JAMM_DECLARATION__";

			if is_declaration {
				file := decl.enclosing_load;
				import := file.enclosing_import;
				module := table_find_pointer(*plugin.modules, import);
				assert(module && !module.declaration);
				module.declaration = decl;
			}
		}
	}
}

finish :: (p: *Metaprogram_Plugin) {
	plugin: *Plugin = xx p;
	assert(plugin.stage == .EXECUTING);

	// TODO: Publish here, making sure it built...? Maybe. We'll see.

	plugin.stage = .FINISHED;
}

shutdown :: (p: *Metaprogram_Plugin) {
	plugin: *Plugin = xx p;
	assert(plugin.stage == .FINISHED);
	plugin.stage = .SHUTDOWN;

	free(plugin.initial_working_directory);
	free(plugin.store_modules_path);

	free_options(plugin.options);

    deinit(*plugin.modules);
}

log_help :: (p: *Metaprogram_Plugin) {
	log(HELP_STRING);
}

communication_proc :: (p: *Metaprogram_Plugin, key: string, value: string) -> bool {
	plugin: *Plugin = xx p;

	if plugin.stage >= .PREPARED {
		log_error("JAMM cannot be configured once it has been prepared\n");
		return false;
	}

	success, message := apply_option(*plugin.options, key, value);
	if !success log_error("Invalid JAMM option: '%' %\n", key, message);
	return success;
}

HELP_STRING :: #string DONE

+JAMM [..OPTIONS]

Resolve JAMM imports in the target program.

Options
	-help						Print this help message.
	-host HOST					Override the default registry host.
	-host VENDOR MODULE HOST	Override the registry host for a given module.
	-publish VENDOR MODULE		Publish the specified module to its registry.
								It needs to be imported and declared somewhere
								in the target program. This will fail if the
								module has already been published as a higher
								version, or if you don't have permission.
	-ssh KEY					Override the default SSH key.
	-ssh HOST KEY				Override the default SSH key for a given host.
	-store STORE				Override the default module store location.

Option Types
	HOST		A valid URI to a module registry host. For now, only the 'file'
				scheme is supported.
	MODULE		A module name.
	SSHREF		The name of an SSH private key in ~/.ssh, or a path to one.
	STORE		A directory path to a module store.
	VENDOR		A module vendor name.

DONE

#import "Basic";
#import "Compiler";
#import "Hash_Table";
#import "String";
