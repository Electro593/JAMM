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

import :: (options: Import_Options, $toplevel_scope := #caller_code) #expand {
	make_import :: (options: Import_Options) -> string {
		uri := make_module_uri(options);
		defer free(uri);
		return tprint("#import,dir \"%\";", uri);
	}

	#insert,scope(toplevel_scope) #run make_module_uri(options);
}

make_module_uri :: (options: Import_Options) -> string {
	host := options.host;
	valid, message := validate_uri(host);
	assert(valid, message);

	vendor := encode_uri_path_segment(options.vendor, allow_wobbly = true);
	defer free(vendor);
	assert(vendor);

	name := encode_uri_path_segment(options.name, allow_wobbly = true);
	defer free(name);
	assert(name);

	version := options.version;
	valid, message = validate_version(version);
	assert(valid, message);

	builder: String_Builder;
	init_string_builder(*builder);

	if host print_to_builder(*builder, "jamm-%", host);
	else print_to_builder(*builder, "jamm:");

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

get_plugin :: () -> *Metaprogram_Plugin {
	return *plugin;
}

#scope_file

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
		// Allows surrogate halves in your utf8 strings. But why?
		allow_wobbly_utf8: bool;

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

	uri_option :: (value: string) -> string #expand {
		valid, message := validate_uri(value);
		if valid return value;
		invalid_option(message);
	}

	ssh_ref_option :: (value: string) -> string #expand {
		valid, message := validate_ssh_ref(value);
		if valid return value;
		invalid_option(message);
	}

	dir_option :: (value: string) -> string #expand {
		valid, message := validate_dir(value);
		if valid return value;
		invalid_option(message);
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
				from := uri_option(options[cursor + 1]);
				to := uri_option(options[cursor + 2]);
				table_set(*plugin.options.host_map, from, to);
				cursor += 3;

			case "-ssh";
				ensure_options(3, "must be followed by a host URI and an SSH key reference");
				host := uri_option(options[cursor + 1]);
				key := ssh_ref_option(options[cursor + 2]);
				table_set(*plugin.options.ssh_map, host, key);
				cursor += 3;

			case "-store";
				ensure_options(2, "must be followed by a directory path");
				plugin.options.store = dir_option(options[cursor + 1]);
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
				plugin.options.publish.host = uri_option(options[cursor + 1]);
				cursor += 2;

			case "-ssh";
				ensure_options(2, "must be followed by an SSH key reference");
				plugin.options.publish.ssh_key = ssh_ref_option(options[cursor + 1]);
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
		// TODO: Consider: adding a note to the import with the full version + build metadata

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

	deinit(*plugin.options.host_map);
	deinit(*plugin.options.ssh_map);
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

    if consume(*key, "compatibility.") {
		if key == "allow_wobbly_utf8" {
			plugin.options.compatibility_options.allow_wobbly_utf8 = bool_option();
        if key == "do_not_skip_expressions_without_notes" {
            plugin.options.compatibility_options.do_not_skip_expressions_without_notes = bool_option();
        } else {
            invalid_key();
        }
    } else if consume(*key, "publish.") {
        if key == "host" {
            plugin.publish_options.host = uri_option(value);
        } else if key == "ssh" {
            plugin.publish_options.ssh_key = ssh_ref_option(value);
        } else {
            invalid_key();
        }
    } else {
    	if key == "help" {
    		plugin.options.print_help = bool_option(value)
    	} else if consume(*key, "host.") {
            host_to := uri_option(value);
            defer free(host_to);
            host_from := uri_option(key);

    		entry, added := find_or_add(*plugin.options.host_map, host_from);
    		if !added {
                free(host_from);
                free(entry.*);
            }
    		entry.* = copy_string(host_to);
    	} else if consume(*key, "ssh.") {
            ssh_key := ssh_ref_option(value);
            defer free(ssh_key);
            ssh_host := uri_option(key);

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

encode_uri_path_segment :: (value: string, allow_wobbly := false, is_first_segment_in_relative_uri := false) -> string {
	HEX_MAP :: "0123456789ABCDEF";

	_utf8: [4] u8;
	utf8 := string.{ utf8.data, utf8.count };

	buffer: [..] u8;
	array_reserve(*buffer, value.count);

	i := 0;
	while i < value.count {
		codepoint, to_advance := read_utf32_codepoint(advance(value, i), allow_wobbly);
		i += to_advance;

		success, length := write_utf32_codepoint(codepoint, utf8, allow_wobbly);
		assert(success);

		for 0 .. length - 1 {
			if !is_alnum(char) {
				if xx char == {
				case #char "!";
				case #char "$";
				case #char "&";
				case #char "'";
				case #char "(";
				case #char ")";
				case #char "*";
				case #char "+";
				case #char ",";
				case #char "-";
				case #char ".";
				case #char ";";
				case #char "=";
				case #char "@";
				case #char "~";
				case #char ":"; if is_first_segment_in_relative_uri #through;
				case;
					array_add(*buffer, #char "%", HEX_MAP[it >> 4], HEX_MAP[it & 0xF]);
					continue;
				}
			}
			array_add(*buffer, it);
		}
	}

	return .{ buffer.data, buffer.count };
}

// The version in Unicode.jai doesn't handle errors correctly
read_utf32_codepoint(s: string, allow_wobbly := false) -> (c: u32, to_advance: int) {
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
		s[0] = c;
		return true, 1;
	}

	if c <= 0x7FF {
		if s.count < 2 return false, 2;
		s[0] = 0xC0 | ((c >> 6) & 0x1F);
		s[1] = 0x80 | (c & 0x3F);
		return true, 2;
	}

	if !allow_wobbly && c >= 0xD800 && c <= 0xDFFF then c = REPLACEMENT;
	if c > 0x10FFFF then c = REPLACEMENT;

	if c <= 0xFFFF {
		if s.count < 3 return false, 3;
		s[0] = 0xE0 | ((c >> 12) & 0x0F);
		s[1] = 0x80 | ((c >> 6) & 0x3F);
		s[2] = 0x80 | (c & 0x3F);
		return true, 3;
	}

	if s.count < 4 return false, 4;
	s[0] = 0xF0 | ((c >> 18) & 0x07);
	s[1] = 0x80 | ((c >> 12) & 0x3F);
	s[2] = 0x80 | ((c >> 6) & 0x3F);
	s[3] = 0x80 | (c & 0x3F);
	return true, 4;
}

validate_uri :: (value: string) -> (valid: bool, message: string) {
	// TODO
	return false, "";
}

validate_ssh_ref :: (value: string) -> (valid: bool, message: string) {
	// TODO
	return false, "";
}

validate_dir :: (value: string) -> (valid: bool, message: string) {
	// TODO
	return false, "";
}

validate_version :: (value: Version) -> (valid: bool, message: string) {
	// TODO
	return false, "";
}

validate_version_constraint :: (value: Version_Constraint) -> (valid: bool, message: string) {
	// TODO
	return false, "";
}

get_license_id :: (name: string) -> int {
	assert(name.count <= 8, "License key too long!");
	value: u64;
	for name  value |= xx it << (56 - it_index * 8);
	return xx value;
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
#import "Hash_Table";
#import "String";
