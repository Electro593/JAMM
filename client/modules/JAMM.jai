Declare_Options :: struct {
	vendor: string;
	name: string;
	version: Version;

	license: License = .UNSPECIFIED;
	authors: [] string = .[];
	repo: string = "";
}

Import_Options :: struct {
	vendor: string;
	name: string;
	version: Version_Constraint;

	host: string = "";
}

Version :: struct {
	major: u64;
	minor: u64;
	patch: u64;
	pre_release: string;
	build_metadata: string;
}

Version_Constraint :: struct {
	major: u64;
	minor: u64;
	patch: u64;
	pre_release: string;

	match: enum {
		EXACT;
		LATEST_PRE_RELEASE;
		LATEST_PATCH;
		LATEST_MINOR;
	} = .EXACT;
}

Module_Id :: struct {
	vendor: string;
	name: string;
}

Module :: struct {
	file: *Message_File;
	declaration: *Code_Node;
}

Plugin :: struct {
	#as using base: Metaprogram_Plugin;

	// Cross-communication between init() and communication_proc()
	is_communication_from_init: bool;
	invalid_option_reason: string;

	stage: enum {
		UNINITIALIZED;
		INITIALIZED;
		PREPARED;
		EXECUTING;
		FINISHED;
		SHUTDOWN;
	} = .UNINITIALIZED;

	// All of these strings need to be allocated on the heap, since they will
	// be freed from it during the shutdown phase.
	Options :: struct {
		// If true, just print help and exit.
		print_help: bool;

		// Module store path override.
		store: string;

		// Per-module host uri overrides.
		// FUTURE: Allow vendor to be omitted, use config if available
		host_map: Table(Module_Id, string, hash_module_id, are_module_ids_equal);

		// Per-host SSH key overrides.
		ssh_map: Table(string, string);

		// Modules to publish.
		publish: Table(Module_Id, void, hash_module_id, are_module_ids_equal);

		Compatibility :: struct {
			// Allow surrogate halves in your utf8 strings. But why?
			allow_wobbly_utf8: bool;

			// Don't skip any expressions, something else will configure that.
			do_not_skip_expressions: bool;
		}

		compatibility: Compatibility;
	}

	options: Options;

	modules: Table(*Message_Import, Module);
}

// TODO: Figure out how to make a declare :: (options: Declare_Options)

import :: (options: Import_Options, $toplevel_scope := #caller_code) #expand {
	make_import :: (options: Import_Options) -> string {
		uri := make_module_uri(options);
		defer free(uri);
		return tprint("#import \"%\";", uri);
	}

	#insert,scope(toplevel_scope) #run make_import(options);
}

make_module_uri :: (options: Import_Options) -> string {
	host := options.host;
	valid, message := validate_uri(host);
	assert(valid, message);

	vendor := encode_uri_path_segment(options.vendor, allow_wobbly = true);
	defer free(vendor);
	assert(vendor != "");

	name := encode_uri_path_segment(options.name, allow_wobbly = true);
	defer free(name);
	assert(name != "");

	version := options.version;
	valid, message = validate_version_constraint(version);
	assert(valid, message);

	builder: String_Builder;
	init_string_builder(*builder);

	if host print_to_builder(*builder, "jamm-%", host);
	else print_to_builder(*builder, "jamm://");

	print_to_builder(*builder, "/%/%", vendor, name);
	print_to_builder(*builder, "/%.%.%", version.major, version.minor, version.patch);

	if version.pre_release
		print_to_builder(*builder, "-%", version.pre_release);

	if #complete version.match == {
	case .EXACT;
	case .LATEST_PRE_RELEASE; append(*builder, "?match=latest-pre-release");
	case .LATEST_PATCH; append(*builder, "?match=latest-patch");
	case .LATEST_MINOR; append(*builder, "?match=latest-minor");
	}

	return builder_to_string(*builder);
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

	return plugin;
}

// You can use this instead of the plugin CLI or manual configuration. However,
// if you want to do anything fancy, you should make an actual plugin interop.
run_plugin :: (build_string: string, plugin_options: [] string = .[], loc := #caller_location) -> bool {
	plugin := get_plugin();

	workspace := compiler_create_workspace("JAMM Default Workspace");
	plugin.workspace = workspace;
	if !plugin.init(plugin, plugin_options) return false;

	options := get_build_options(workspace);
	options.output_type = .NO_OUTPUT;
	options.write_added_strings = false;

	// TODO: HACK: Fix this
	import_path: [..] string;
	array_add(*import_path, "../jamm/client/modules");
	array_add(*import_path, ..options.import_path);
	options.import_path = import_path;

	set_build_options(options, workspace, loc=loc);

	flags: Intercept_Flags;
	plugin.before_intercept(plugin, *flags);
	compiler_begin_intercept(workspace, flags);

	plugin.add_source(plugin);
	add_build_string(build_string, workspace);

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

make_communication_key :: (subkeys: ..string) -> string {
	if !subkeys.count return "";

	result: [..] u8;

	base_count := subkeys.count - 1;
	for subkeys base_count += it.count;
	array_reserve(*result, base_count);

	for subkey: subkeys {
		if it_index array_add(*result, #char ".");

		for subkey {
			if it == {
			case #char "."; #through;
			case #char "/"; #through;
			case #char "\\"; array_add(*result, #char "\\", it);
			case; array_add(*result, it);
			}
		}
	}

	return .{ result.count, result.data };
}

#scope_file

init :: (p: *Metaprogram_Plugin, options: [] string) -> bool {
	plugin: *Plugin = xx p;
	assert(plugin.stage == .UNINITIALIZED);

	report_invalid :: (reason: string) #expand {
		relevant_options := array_view(`options, `cursor, `cursor_delta);
		log_error("Invalid JAMM options %: %\n", `options, reason);
		log_error(HELP_STRING);
		`return false;
	}

	ensure_options :: (count: int, reason: string) #expand {
		if `cursor + `cursor_delta + count <= `options.count
			report_invalid(reason);
		`cursor_delta += count;
	}

	dispatch :: (key: string, value: string) #expand {
		plugin.is_communication_from_init = true;
		defer plugin.is_communication_from_init = false;
		if `plugin.communication_proc(`plugin, key, value) return;
		report_invalid(plugin.invalid_option_reason);
		`return false;
	}

	cursor := 0;
	cursor_delta := 0;
	while cursor < options.count {
		cursor_delta = 1;
		defer cursor += cursor_delta;

		if options[cursor] == {
		case "-help";
			dispatch("help", "true");

		case "-host";
			ensure_options(1, "must be followed by a registry host URI");
			if cursor + 2 >= options.count || begins_with(options[cursor + 2], "-") {
				dispatch("host", options[cursor + 1]);
				continue;
			}

			ensure_options(2, "must be followed by a module vendor, name, and a host URI");
			key := make_communication_key("host", options[cursor + 1], options[cursor + 2]);
			dispatch(key, options[cursor + 3]);

		case "-publish";
			ensure_options(3, "must be followed by a module vendor and name");
			key := make_communication_key("publish", options[cursor + 1], options[cursor + 2]);
			dispatch(key, "");

		case "-ssh";
			ensure_options(1, "must be followed by an SSH key reference");
			if cursor + 2 >= options.count || begins_with(options[cursor + 2], "-") {
				dispatch("ssh", options[cursor + 1]);
				continue;
			}

			ensure_options(1, "must be followed by a host URI and an SSH key reference");
			key := make_communication_key("ssh", options[cursor + 1]);
			dispatch(key, options[cursor + 2]);

		case "-store";
			ensure_options(1, "must be followed by a directory path");
			dispatch("store", options[cursor + 1]);

		case; report_invalid("is not a valid option");
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

	if !plugin.options.store {
		plugin.options.store = get_default_store_path();
		if !plugin.options.store
			log("Could not determine the path to a module store. Will fallback to no caching.");
	}

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
		if !begins_with(target_name, "jamm") return;

// 		if begins_with(target_name, "jamm://") {
// 			if !plugin.options.host {
// 				log_error("Could not determine a registry host URI for import '%'\n", target_name);
// 				return;
// 			}
//
// 			rest := advance(target_name, "jamm://".count);
// 			target_name = tprint("jamm-%/modules%", plugin.options.host, rest);
// 		}

		print("%\n", failed_import.*);

		// TODO: Remap the import here
		// TODO: Consider: adding a note to the import with the full version + build metadata

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

	if plugin.options.store
		free(plugin.options.store);

	for plugin.options.host_map {
		remove it;
		free(it_index);
		free(it);
	}
	deinit(*plugin.options.host_map);

	for plugin.options.ssh_map {
		remove it;
		free(it_index);
		free(it);
	}
	deinit(*plugin.options.ssh_map);

	for plugin.options.publish {
		remove it;
		free(it_index);
	}
	deinit(*plugin.options.publish);

	deinit(*plugin.modules);
}

log_help :: (p: *Metaprogram_Plugin) {
	log(HELP_STRING);
}

communication_proc :: (p: *Metaprogram_Plugin, key: string, value: string) -> bool {
	plugin: *Plugin = xx p;
	original_key := key;

	if plugin.stage >= .PREPARED {
		log_error("JAMM cannot be configured once it has been prepared\n");
		return false;
	}

	invalid_key :: (reason: string = "Option is not recognized") #expand {
		if plugin.is_communication_from_init then plugin.invalid_option_reason = reason;
		else log_error("Invalid JAMM option '%': %\n", `original_key, reason);
		`return false;
	}

	invalid_value :: (reason: string) #expand {
		if plugin.is_communication_from_init then plugin.invalid_option_reason = reason;
		else log_error("Invalid value for JAMM option '%': '%' %\n", `original_key, `value, reason);
		`return false;
	}

	split_key :: (key: string) -> [] string #expand {
		if !key return .[];

		base: [] u8;
		base.data = talloc(key.count);
		base.count = key.count;

		subkeys: [..] string;

		subkey := array_add(*subkeys);
		subkey.data = base.data;

		is_escape := false;

		for key {
			if is_escape {
				is_escape = false;
				if it == {
				case #char "."; #through;
				case #char "/"; #through;
				case #char "\\";
				case; invalid_key("Invalid key escape (must match /\\[./\\]/)");
				}
			} else {
				if it == {
				case #char ".";
					if !subkey.count break;
					data := subkey.data + subkey.count;
					subkey = array_add(*subkeys);
					subkey.data = data;
					continue;
				case #char "\\";
					is_escape = true;
					continue;
				}
			}

			subkey.count += 1;
			subkey.*[subkey.count - 1] = it;
		}

		if is_escape
			invalid_key("Key cannot end with an unpaired escape ('\\')");

		if !subkey.count
			invalid_key("Key cannot have an empty component");

		return subkeys;
	}

    next :: () -> string #expand {
		if `subkey_index >= `subkeys.count - 1 return "";
		`subkey_index += 1;
		return `subkeys[`subkey_index];
    }

    next :: (desired: string) -> bool #expand {
		if `subkey_index >= `subkeys.count - 1 return false;
		if !equal_nocase(`subkeys[`subkey_index + 1], desired) return false;
		`subkey_index += 1;
		return true;
    }

	assert_last :: () #expand {
		if `subkey_index != `subkeys.count - 1
			invalid_key();
	}

	bool_option :: (value: string) -> bool #expand {
		if equal_nocase(value, "true") return true;
		if equal_nocase(value, "false") return false;
		invalid_value("must be 'true' or 'false'");
	}

	uri_option :: (value: string) -> string #expand {
		valid, message := validate_uri(value);
		if valid return copy_string(value);
		invalid_value(message);
	}

	ssh_ref_option :: (value: string) -> string #expand {
		valid, message := validate_ssh_ref(value);
		if valid return copy_string(value);
		invalid_value(message);
	}

	dir_option :: (value: string) -> string #expand {
		valid, message := validate_dir(value);
		if valid return copy_string(value);
		invalid_value(message);
	}

	subkeys := split_key(key);
	defer array_free(subkeys);

	subkey_index := -1;
	while subkey_index < subkeys.count {
		if next("compatibility") {
			if next("allow_wobbly_utf8") {
				assert_last();
				plugin.options.compatibility.allow_wobbly_utf8 = bool_option(value);
	        } else if next("do_not_skip_expressions") {
				assert_last();
	            plugin.options.compatibility.do_not_skip_expressions = bool_option(value);
	        } else {
	            invalid_key();
	        }
	    } else if next("help") {
			assert_last();
	        plugin.options.print_help = bool_option(value);
		} else if next("host") {
			vendor := next();
			module := next();
			assert_last();
			if !!vendor != !!module invalid_key("Must specify both vendor.module or neither");

	        host := uri_option(value);
	        module_id := Module_Id.{ copy_string(vendor), copy_string(module) };
			entry, added := find_or_add(*plugin.options.host_map, module_id);
			if !added {
				free(module_id);
				free(entry.*);
			}
			entry.* = host;
		} else if next("publish") {
			vendor := next();
			module := next();
			assert_last();
			if !vendor || !module invalid_key();

	        module_id := Module_Id.{ copy_string(vendor), copy_string(module) };
			_, added := find_or_add(*plugin.options.publish, module_id);
			if !added free(module_id);
		} else if next("ssh") {
			subkey := next();
			assert_last();

			ssh_key := ssh_ref_option(value,, temp);
			ssh_host := uri_option(subkey);
			entry, added := find_or_add(*plugin.options.ssh_map, ssh_host);
			if !added {
				free(ssh_host);
				free(entry.*);
			}
			entry.* = copy_string(ssh_key);
		} else if next("store") {
			assert_last();
			if plugin.options.store free(plugin.options.store);
			plugin.options.store = dir_option(value);
        } else {
            invalid_key();
		}
	}

	return true;
}

encode_uri_path_segment :: (
	value: string,
	allow_wobbly := false,
	should_encode_delim: (char: u8) -> bool = null
) -> string {
	HEX_MAP :: "0123456789ABCDEF";

	// TODO: scheme-aware should_encode_delim

	_utf8: [4] u8;
	utf8 := string.{ _utf8.count, _utf8.data };

	buffer: [..] u8;
	array_reserve(*buffer, value.count);

	i := 0;
	while i < value.count {
		codepoint, to_advance := read_utf32_codepoint(advance(value, i), allow_wobbly);
		i += to_advance;

		success:, utf8.count = write_utf32_codepoint(utf8, codepoint, allow_wobbly);
		assert(success);

		for utf8 {
			if is_alnum(it) || it == #char "-" || it == #char "." || it == #char "~" {
				array_add(*buffer, it);
				continue;
			}

			if it == {
			case #char "!"; #through;
			case #char "#"; #through;
			case #char "$"; #through;
			case #char "&"; #through;
			case #char "'"; #through;
			case #char "("; #through;
			case #char ")"; #through;
			case #char "*"; #through;
			case #char "+"; #through;
			case #char ","; #through;
			case #char "/"; #through;
			case #char ":"; #through;
			case #char ";"; #through;
			case #char "="; #through;
			case #char "?"; #through;
			case #char "@"; #through;
			case #char "["; #through;
			case #char "]";
				if should_encode_delim && !should_encode_delim(it) {
					array_add(*buffer, it);
					continue;
				}
			}

			array_add(*buffer, #char "%", HEX_MAP[it >> 4], HEX_MAP[it & 0xF]);
		}
	}

	return .{ buffer.count, buffer.data };
}

// The version in Unicode.jai doesn't handle errors correctly
read_utf32_codepoint :: (s: string, allow_wobbly := false) -> (c: u32, to_advance: int) {
	REPLACEMENT : u32 : 0x0000FFFD;

	if s.count < 1 return 0, 0;
	c0: u32 = s[0];

	if c0 <= 0x7F return c0 & 0x7F, 1;

	if c0 <= 0xBF return REPLACEMENT, 1; // Lone continuation byte
	if (c0 & 0xFE) == 0xC0 return REPLACEMENT, 1; // Overlong 2-byte
	if c0 > 0xF4 return REPLACEMENT, 1; // Too large

	if s.count < 2 return REPLACEMENT, 1; // Not enough bytes
	c1: u32 = s[1];
	if (c1 & 0xC0) != 0x80 return REPLACEMENT, 1; // Not a continuation byte

	if c0 <= 0xDF return (c0 & 0x1F) << 6 | (c1 & 0x3F), 2;

	if c0 == 0xE0 && (c1 & 0x20) == 0 return REPLACEMENT, 1; // Overlong 3-byte
	if !allow_wobbly && c0 == 0xED && c1 > 0x9F return REPLACEMENT, 1; // Surrogate half
	if c0 == 0xF0 && (c1 & 0xB0) == 0 return REPLACEMENT, 1; // Overlong 4-byte
	if c0 == 0xF4 && c1 > 0x8F return REPLACEMENT, 1; // Too large

	if s.count < 3 return REPLACEMENT, 2; // Not enough bytes
	c2: u32 = s[2];
	if (c2 & 0xC0) != 0x80 return REPLACEMENT, 2; // Not a continuation byte

	if c0 <= 0xEF return (c0 & 0x0F) << 12 | (c1 & 0x3F) << 6 | (c2 & 0x3F), 3;

	if s.count < 4 return REPLACEMENT, 3; // Not enough bytes
	c3: u32 = s[3];
	if (c3 & 0xC0) != 0x80 return REPLACEMENT, 3; // Not a continuation byte

	return (c0 & 0x07) << 18 | (c1 & 0x3F) << 12 | (c2 & 0x3F) << 6 | (c3 & 0x3F), 4;
}

// Assumes host endianness
write_utf32_codepoint :: (s: string, c: u32, allow_wobbly := false) -> (success: bool, count: int) {
	REPLACEMENT : u32 : 0x0000FFFD;

	if c <= 0x7F {
		if s.count < 1 return false, 1;
		s[0] = xx c;
		return true, 1;
	}

	if c <= 0x7FF {
		if s.count < 2 return false, 2;
		s[0] = xx (0xC0 | ((c >> 6) & 0x1F));
		s[1] = xx (0x80 | (c & 0x3F));
		return true, 2;
	}

	if !allow_wobbly && c >= 0xD800 && c <= 0xDFFF then c = REPLACEMENT;
	if c > 0x10FFFF then c = REPLACEMENT;

	if c <= 0xFFFF {
		if s.count < 3 return false, 3;
		s[0] = xx (0xE0 | ((c >> 12) & 0x0F));
		s[1] = xx (0x80 | ((c >> 6) & 0x3F));
		s[2] = xx (0x80 | (c & 0x3F));
		return true, 3;
	}

	if s.count < 4 return false, 4;
	s[0] = xx (0xF0 | ((c >> 18) & 0x07));
	s[1] = xx (0x80 | ((c >> 12) & 0x3F));
	s[2] = xx (0x80 | ((c >> 6) & 0x3F));
	s[3] = xx (0x80 | (c & 0x3F));
	return true, 4;
}

validate_uri :: (value: string) -> (valid: bool, message := "") {
	if !value return true;

	// TODO: Implement uri validation

	return false, "";
}

validate_ssh_ref :: (value: string) -> (valid: bool, message := "") {
	if !value return true;

	PATH_SEPARATOR :: #ifx OS == .WINDOWS then "\\" else "/";

	is_path := contains(value, "/");
	#if OS == .WINDOWS then is_path |= contains(value, "\\");
	if is_path {
		#if OS == .WINDOWS {
			value := replace(value, "/", "\\");
			defer free(value);
		}

		if !file_exists(value)
			return false, "was not able to be opened";

		return true;
	}

	home, success := get_home_directory();
	if !success {
		username:, success = get_username();
		if success
			home, success = get_home_directory(username);
	}

	if !success
		return false, "was not able to find the user's home directory";

	builder: String_Builder;
	init_string_builder(*builder);

	append(*builder, home);
	if (home[home.count - 1] != PATH_SEPARATOR) append(*builder, PATH_SEPARATOR);
	print_to_builder(*builder, ".ssh%%", PATH_SEPARATOR, value);

	path := builder_to_string(*builder);
	defer free(path);

	if !file_exists(path)
		return false, tprint("was not able to be found or opened at '%'", path);

	return true;
}

validate_dir :: (value: string) -> (valid: bool, message := "") {
	if !value return true;

	is_dir, success := is_directory(value);
	if !success return false, "was not able to be opened";

	if !is_dir return false, "is not a directory";

	return true;
}

validate_version :: (using value: Version) -> (valid: bool, message := "") {
	valid, message = validate_semver_identifiers(pre_release);
	if !valid return false, tprint("has a pre-release which %", message);

	valid, message = validate_semver_identifiers(build_metadata, allow_leading = true);
	if !valid return false, tprint("has build metadata which %", message);

	return true;
}

validate_version_constraint :: (using value: Version_Constraint) -> (valid: bool, message := "") {
	if match == .LATEST_MINOR && !major
		return false, "specifies match-latest-minor with major version 0";
	if match == .LATEST_PATCH && !minor
		return false, "specifies match-latest-patch with minor version 0";
	if match == .LATEST_PRE_RELEASE && !patch
		return false, "specifies match-latest-pre-release with patch version 0";

	valid, message := validate_semver_identifiers(pre_release);
	if !valid return false, tprint("has a pre-release which %", message);

	return true;
}

validate_semver_identifiers :: (value: string, allow_leading := false) -> (valid: bool, message := "") {
	if !value return true;

	identifier_start := 0;
	starts_with_0 := false;
	has_nondigit := false;

	for 0 .. value.count {
		if it == value.count || value[it] == #char "." {
			if it == identifier_start
				return false, "has an empty identifier";
			if !allow_leading && it > identifier_start + 1 && starts_with_0 && !has_nondigit
				return false, "has a numeric identifier with a leading zero";

			identifier_start = it + 1;
			has_nondigit = false;
			continue;
		}

		c := value[it];

		if it == identifier_start
			starts_with_0 = c == #char "0";

		is_nondigit := is_alpha(c) || c == #char "-";
		has_nondigit |= is_nondigit;

		if !is_nondigit && !is_digit(c)
			return false, "has an identifier with an invalid character (must be [0-9A-Za-z-])";
	}

	return true;
}

#if OS == .WINDOWS {
	get_default_config_path :: () -> string {
		base := get_local_app_data_path(,, temp);
		if !base return "";
		return sprint("%/JAMM/Config", base);
	}

	get_default_host_path :: () -> string {
		base := get_local_app_data_path(,, temp);
		if !base return "";
		return sprint("%/JAMM/Registry", base);
	}

	get_default_store_path :: () -> string {
		base := get_local_app_data_path(,, temp);
		if !base return "";
		return sprint("%/JAMM/Store", base);
	}

	get_local_app_data_path :: () -> string {
		Windows :: #import "Windows";
	    ole32    :: #library,system "ole32";
	    shell32  :: #library,system "shell32";

	    SHGetKnownFolderPath :: (nFolder: Windows.REFGUID, dwFlags: Windows.DWORD, hToken: Windows.HANDLE, pszPath: **u16) -> Windows.HRESULT #foreign shell32;
	    CoTaskMemFree :: (data: *void) #foreign ole32;

		FOLDERID_LocalAppData :: #run Windows.uid("F1B32785-6FBA-4FCF-9D55-7B8E7F157091");

	    path_data: *u16;
	    hr := SHGetKnownFolderPath(*FOLDERID_LocalAppData, Windows.KF_FLAG_CREATE, null, *path_data);
	    defer CoTaskMemFree(path_data);
	    if !Windows.SUCCEEDED(hr) return "";

	    path := Windows.wide_to_utf8(path_data);
		defer free(path);

		return replace(path, "\\", "/");
	}
} else {
	get_default_config_path :: () -> string {
		base := get_env("XDG_CONFIG_HOME");
		if base return tprint("%/jamm", trim_slash(base));
		home := get_env("HOME");
		if !home return "";
		return sprint("%/.config/jamm", trim_slash(home));
	}

	get_default_host_path :: () -> string {
		base := get_env("XDG_DATA_HOME");
		if base return tprint("%/jamm/registry", trim_slash(base));
		home := get_env("HOME");
		if !home return "";
		return sprint("%/.local/share/jamm/registry", trim_slash(home));
	}

	get_default_store_path :: () -> string {
		base := get_env("XDG_CACHE_HOME");
		if base return tprint("%/jamm/store", trim_slash(base));
		home := get_env("HOME");
		if !home return "";
		return sprint("%/.cache/jamm/store", trim_slash(home));
	}

	get_env :: (key: *u8) -> string {
		POSIX :: #import "POSIX";
		value := POSIX.getenv(key);
		return ifx value then to_string(value);
	}
}

are_module_ids_equal :: (a: Module_Id, b: Module_Id) -> bool {
	return a.vendor == b.vendor && a.name == b.name;
}

hash_module_id :: (id: Module_Id) -> u32 {
	Hash :: #import "Hash";
	return Hash.get_hash(id.vendor) ^ Hash.get_hash(id.name);
}

free :: (id: Module_Id) {
	free(id.vendor);
	free(id.name);
}

trim_slash :: (path: string) -> string {
	return ifx ends_with(path, "/")
		then .{ path.count - 1, path.data }
		else path;
}

get_license_id :: (name: string) -> int {
	assert(name.count <= 8, "License key too long!");
	value: u64;
	for name  value |= xx it << (56 - it_index * 8);
	return xx value;
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

#scope_export

License :: enum {
	UNSPECIFIED :: 0;
	UNLICENSED  :: 1;

	// Based on SPDX: https://spdx.org/licenses/.
	// There are many more licenses than just this, but here are the most
	// common ones.

	APACHE_1_0                    :: #run get_license_id("APACHE10");  // Apache-1.0
	APACHE_1_1                    :: #run get_license_id("APACHE11");  // Apache-1.1
	APACHE_2_0                    :: #run get_license_id("APACHE20");  // Apache-2.0
	BSD_1_CLAUSE                  :: #run get_license_id("BSD1C");     // BSD-1-Clause
	BSD_2_CLAUSE                  :: #run get_license_id("BSD2C");     // BSD-2-Clause
	BSD_3_CLAUSE                  :: #run get_license_id("BSD3C");     // BSD-3-Clause
	BSD_4_CLAUSE                  :: #run get_license_id("BSD4C");     // BSD-4-Clause
	BLESSING                      :: #run get_license_id("BLESSING");  // blessing
	GPL_1_0_ONLY                  :: #run get_license_id("GPL10");     // GPL-1.0-only
	GPL_1_0_OR_LATER              :: #run get_license_id("GPL10+");    // GPL-1.0-or-later
	GPL_2_0_ONLY                  :: #run get_license_id("GPL20");     // GPL-2.0-only
	GPL_2_0_OR_LATER              :: #run get_license_id("GPL20+");    // GPL-2.0-or-later
	GPL_3_0_ONLY                  :: #run get_license_id("GPL30");     // GPL-3.0-only
	GPL_3_0_OR_LATER              :: #run get_license_id("GPL30+");    // GPL-3.0-or-later
	ISC                           :: #run get_license_id("ISC");       // ISC
	MIT                           :: #run get_license_id("MIT");       // MIT
	MPL_1_0                       :: #run get_license_id("MPL10");     // MPL-1.0
	MPL_1_1                       :: #run get_license_id("MPL11");     // MPL-1.1
	MPL_2_0                       :: #run get_license_id("MPL20");     // MPL-2.0
	MPL_2_0_NO_COPYLEFT_EXCEPTION :: #run get_license_id("MPL20NCE");  // MPL-2.0-no-copyleft-exception
	UNICODE_3_0                   :: #run get_license_id("UNICOD30");  // Unicode-3.0
	UNLICENSE                     :: #run get_license_id("UNLICENS");  // Unlicense
}

#scope_file

#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "Hash_Table";
#import "String";
#import "System";
