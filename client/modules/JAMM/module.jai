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

Module_ID :: struct {
	vendor: string;
	module: string;
}

Module :: struct {
	file: *Message_File;
	declaration: *Code_Node;
}

// TODO: Figure out how to make a declare :: (options: Declare_Options)

import :: (options: Import_Options, $toplevel_scope := #caller_code) #expand {
	#insert,scope(toplevel_scope) #run tprint("#import \"%\";", make_module_uri(options,, temp));
}

make_module_uri :: (options: Import_Options) -> string {
	host := options.host;
	valid, message := validate_uri(host);
	assert(valid, message);

	// TODO: Handle .. and . segments, plus anything forbidden on windows?
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

    // TODO: Host needs to be escaped
	print_to_builder(*builder, "jamm:%/%/%", host, vendor, name);
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

#scope_module

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
		path_overwrite_separators(path, #char "/");
		return path;
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

are_module_ids_equal :: (a: Module_ID, b: Module_ID) -> bool {
	return a.vendor == b.vendor && a.module == b.module;
}

hash_module_id :: (id: Module_ID) -> u32 {
	Hash :: #import "Hash";
	return Hash.get_hash(id.vendor) ^ Hash.get_hash(id.module);
}

trim_slash :: (path: string) -> string {
	if ends_with(path, "/") return .{ path.count - 1, path.data };
	return path;
}

get_normalized_cwd :: () -> string {
	cwd := copy_string(get_working_directory());
	#if OS == .WINDOWS then path_overwrite_separators(cwd, #char "/");
	return trim_slash(cwd);
}

get_license_id :: (name: string) -> int {
	assert(name.count <= 8, "License key too long!");
	value: u64;
	for name  value |= xx it << (56 - it_index * 8);
	return xx value;
}

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
#import "System";

#load "engine.jai";
#load "options.jai";
#load "plugin.jai";
