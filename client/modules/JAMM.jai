#module_parameters (DEBUG := true);

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
	alias: string = "";
}

Version :: struct {
	major: int;
	minor: int;
	patch: int;
}

Version_Constraint :: struct {
	major: int;
	minor: int;
	patch: int;

	match: enum {
		EXACT;
		LATEST_PATCH;
		LATEST_MINOR;
		LATEST;
	} = .EXACT;
}

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

import :: (options: Import_Options, $toplevel_scope := #caller_code) #expand {
	make_import :: (using options: Import_Options) -> string {
		// TODO: Make this actually a thing
		path := sprint("/home/aria/programming/jai-json/modules/%", name);
		defer free(path);
		is_file := true;

		if is_file return tprint("#import,file \"%.jai\";", path);
		return tprint("#import,dir \"%/module.jai\";", path);
	}

	#insert,scope(toplevel_scope) #run make_import(options);
}

get_plugin :: () -> *Metaprogram_Plugin {
	return *plugin;
}

#scope_file

get_license_id :: (name: string) -> int {
	assert(name.count <= 8, "License key too long!");
	value: u64;
	for name  value |= xx it << (56 - it_index * 8);
	return xx value;
}

print_node :: (node: *Code_Node, indent := 0) {
	_spaces: [256] u8;
	memset(_spaces.data, #char " ", _spaces.count);
	spaces: string = .{ data = _spaces.data, count = _spaces.count };

	print_node :: (node: *Code_Node, spaces: string, indent: int) {
		if !node return;

		space := spaces;
		space.count = indent * 2;

		if node.kind == {
		case .IDENT; print("%%\n", space, (.*) cast(*Code_Ident) node);
		case .LITERAL; print("%%\n", space, (.*) cast(*Code_Literal) node);
		case .NOTE; print("%%\n", space, (.*) cast(*Code_Note) node);
		case .DIRECTIVE_IMPORT; print("%%\n", space, (.*) cast(*Code_Directive_Import) node);
		case .DECLARATION;
			decl: *Code_Declaration = xx node;
			print("%%\n", space, decl.*);
			print_node(decl.expression, spaces, indent + 1);
		case .PROCEDURE_HEADER;
			header: *Code_Procedure_Header = xx node;
			print("%%\n", space, header.*);
			for header.arguments print_node(it, spaces, indent + 1);
		case .PROCEDURE_CALL;
			call: *Code_Procedure_Call = xx node;
			print("%%\n", space, call.*);
			print_node(call.resolved_procedure_expression, spaces, indent + 1);
			for call.arguments_unsorted print_node(it.expression, spaces, indent + 1);
		case;
			print("%%\n", space, node.kind);
		}
	}

	print_node(node, spaces, indent);
}

plugin: JAMM_Plugin = .{
	init             = jamm_init,
	before_intercept = jamm_before_intercept,
	add_source       = jamm_add_source,
	message          = jamm_message,
	shutdown         = jamm_shutdown,
	log_help         = jamm_log_help
};

JAMM_Module :: struct {
	file: *Message_File;
	declaration: *Code_Node;
}

JAMM_Plugin :: struct {
	#as using base: Metaprogram_Plugin;

	stage: enum {
		UNINITIALIZED;
		INITIALIZED;
		EXECUTING;
		FINISHED;
		SHUTDOWN;
	} = .UNINITIALIZED;

	options: struct {
		// If true, just print help and exit.
		print_help: bool;

		// Per-host uri overrides.
		host_map: Table(string, string);

		// Per-host SSH key overrides.
		ssh_map: Table(string, string);

		// Module store path override.
		store: string;
	}

	publish: bool;
	publish_options: struct {
		// Target registry host override.
		host: string;

		// Target host SSH key override.
		ssh_key: string;
	}

	compatibility_options: struct {
		// Don't tell the intercept to skip expressions without notes
		do_not_skip_expressions_without_notes: bool;
	}

	modules: Table(*Message_Import, JAMM_Module);
}

jamm_init :: (p: *Metaprogram_Plugin, options: [] string) -> bool {
	plugin: *JAMM_Plugin = xx p;

	invalid_option :: (reason := "is not a valid option") #expand {
		full_reason := sprint("'%%' %", `command_prefix, `options[`cursor], reason);
		defer free(full_reason);
		log_error("Invalid arguments for JAMM: '%': %.\n%", `options, full_reason, `help_string);
		`return false;
	}

	command_or_invalid :: () #expand {
		if begins_with(`options[`cursor], "-") invalid_option();
		`parse_mode = .NEXT_COMMAND;
	}

	ensure_options :: (count: int, reason: string) #expand {
		if `cursor + count < `options.count
			invalid_option(reason);
	}

	parse_mode: enum {
		NONE;
		NEXT_COMMAND;
		PUBLISH;
	} = .NONE;
	command_prefix := "";
	help_string := HELP_STRING;

	cursor := 0;
	while cursor < options.count {
		if #complete parse_mode == {
		case .NONE;
			if options[cursor] == {
			case "-help";
				plugin.options.print_help = true;
				cursor += 1;

			case "-host";
				ensure_options(3, "must be followed by an original host URI and a new host URI");
				from: options[cursor + 1];
				to: options[cursor + 2];
				// TODO: Validate the uris
				table_set(*plugin.options.host_map, from, to);
				cursor += 3;

			case "-ssh";
				ensure_options(3, "must be followed by a host URI and an SSH key reference");
				host: options[cursor + 1];
				key: options[cursor + 2];
				// TODO: Validate the uri and key
				table_set(*plugin.options.ssh_map, host, key);
				cursor += 3;

			case "-store";
				ensure_options(2, "must be followed by a directory path");
				// TODO: Validate the path
				plugin.options.store = options[cursor + 1];
				cursor += 2;

			case; command_or_invalid();
			}

		case .NEXT_COMMAND;
			if options[cursor] == {
			case "publish";
				plugin.options.publish = true;
				parse_mode = .PUBLISH;
				cursor += 1;

			case; invalid_option("is not a valid command");
			}

		case .PUBLISH;
			command_prefix = "publish ";
			help_string = PUBLISH_HELP_STRING;

			if options[cursor] == {
			case "-host";
				ensure_options(2, "must be followed by a host URI");
				// TODO: Validate the uri
				plugin.options.publish.host = options[cursor + 1];
				cursor += 2;

			case "-ssh";
				ensure_options(2, "must be followed by an SSH key reference");
				// TODO: Validate the key
				plugin.options.publish.ssh_key = options[cursor + 1];
				cursor += 2;

			case; command_or_invalid();
			}
		}
	}

	plugin.stage = .INITIALIZED;
	return true;
}

jamm_before_intercept :: (p: *Metaprogram_Plugin, flags: *Intercept_Flags) {
	plugin: *JAMM_Plugin = xx p;
	plugin.stage = .EXECUTING;

	// TODO: Add sensible defaults for store and publish host

	if plugin.options.help {
		if #complete plugin.options.command_kind == {
		case .NONE; log(HELP_STRING);
		case .PUBLISH; log(PUBLISH_HELP_STRING);
		}
		exit(0);
	}

	if #complete plugin.options.command_kind == {
	case .NONE;

	case .PUBLISH;
		*Intercept_Flags &= ~.SKIP_DECLARATIONS;
		if !plugin.options.compatibility_do_not_skip_expressions_without_notes
			*Intercept_Flags |= .SKIP_EXPRESSIONS_WITHOUT_NOTES;
	}

}

jamm_add_source :: (p: *Metaprogram_Plugin) {
	plugin: *JAMM_Plugin = xx p;

	add_build_string("__JAMM__ :: 0;", p.workspace, cast(*Message) null);
}

jamm_message :: (p: *Metaprogram_Plugin, message: *Message) {
	plugin: *JAMM_Plugin = xx p;

	if message.kind == {
	case .FAILED_IMPORT;
		failed_import: *Message_Failed_Import = xx message;
		// TODO: Remap the import here

	case .IMPORT;
		import: *Message_Import = xx message;
		table_set(*plugin.modules, import, .{});

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

jamm_finish :: (p: *Metaprogram_Plugin) {
	plugin: *JAMM_Plugin = xx p;

	// TODO: Publish here, making sure it built...? Maybe. We'll see.

	plugin.stage = .FINISHED;
}

jamm_shutdown :: (p: *Metaprogram_Plugin) {
	plugin: *JAMM_Plugin = xx p;
	plugin.stage = .SHUTDOWN;

	deinit(*plugin.modules);
}

jamm_log_help :: (p: *Metaprogram_Plugin) {
	log(HELP_STRING);
}

jamm_communication_proc :: (p: *Metaprogram_Plugin, key: string, value: string) -> bool {
	plugin: *JAMM_Plugin = xx p;

    consume :: (key: *string, prefix: string) -> bool {
        if begins_with(key, prefix) {
            advance(key, prefix.count);
            return true;
        }
        return false;
    }

	invalid_key :: (reason: string = "Unrecognized option") #expand {
		log_error("Invalid JAMM communication key '%': %\n", `key, reason);
		`return false;
	}

	invalid_value :: (reason: string) #expand {
		log_error("Invalid value for JAMM communication key '%': '%' %\n", `key, `value, reason);
		`return false;
	}

	if plugin.stage >= .EXECUTING
		invalid_key("JAMM cannot be configured once it has begun executing");

	bool_option :: (value: string) -> bool #expand {
		if equals_nocase(value, "true") return true;
		if equals_nocase(value, "false") return false;
		invalid_value("is not a bool");
	}

	host_option :: (value: string) -> string #expand {
		if validate_host(value) return copy_string(value);
		invalid_value("is not a valid host registry URI");
	}

	key_option :: (value: string) -> string #expand {
		if validate_key(value) return copy_string(value);
		invalid_value("is not a valid SSH key reference");
	}

	dir_option :: (value: string) -> string #expand {
		if validate_dir(value) return copy_string(value);
		invalid_value("is not a valid directory");
	}

    if consume(*key, "compatibility.") {
        if key == "do_not_skip_expressions_without_notes" {
            plugin.options.compatibility_options.do_not_skip_expressions_without_notes = bool_option();
        } else {
            invalid_key();
        }
    } else if consume(*key, "publish.") {
        if key == "host" {
            plugin.publish_options.host = host_option(value);
        } else if key == "ssh" {
            plugin.publish_options.ssh_key = key_option(value);
        } else {
            invalid_key();
        }
    } else {
    	if key == "help" {
    		plugin.options.print_help = bool_option(value)
    	} else if consume(*key, "host.") {
            host_to := host_option(value);
            defer free(host_to);
            host_from := host_option(key);

    		entry, added := find_or_add(*plugin.options.host_map, host_from);
    		if !added {
                free(host_from);
                free(entry.*);
            }
    		entry.* = copy_string(host_to);
    	} else if consume(*key, "ssh.") {
            ssh_key := key_option(value);
            defer free(ssh_key);
            ssh_host := host_option(key);

            entry, added := find_or_add(*plugin.options.ssh_map, ssh_host);
            if !added {
                free(ssh_host);
                free(entry.*);
            }
            entry.* = copy_string(ssh_key);
        } else if key == "store" {
            plugin.options.store = dir_option(value);
        } else {
            invalid_key();
        }
    }

	return true;
}


HELP_STRING :: #string DONE

+JAMM [..OPTIONS] [ .. COMMAND [..] ]

Resolve JAMM imports in the target program.

Options
	-help			Print this help message, or that of the command.
	-host FROM TO	Override the given FROM host URI to the given TO host URI.
	-ssh URI KEY	Override the default SSH agent with a specific key for a
					given host URI. See `+JAMM -help publish` for URI and KEY
					constraints.
	-store DIR		Override the default module store location. DIR must be a
					valid directory on your computer.

Commands
	publish			Publish your module to the module registry.

DONE

PUBLISH_HELP_STRING :: #string DONE

+JAMM [..] publish [..OPTIONS]

Publish your module to the module registry.

This will fail if the module has already been published as a higher version, or
if you have insufficient permissions.

ptions:
	-host URI	Override the default target registry host. URI must be a valid
				network or directory URI. This can be different than the source
				registry!
	-ssh KEY	Override the default SSH agent with a specific key. KEY must be
				a valid public key name in ~/.ssh, or a relative or absolute
				path to a public key.

DONE

#import "Basic";
#import "Compiler";
#import "File";
#import "Hash_Table";
#import "String";
