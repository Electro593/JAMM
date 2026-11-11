#scope_export

// All of these strings need to be allocated on the heap, or whatever your
// context allocator is.
Options :: struct {
	// If true, just print help and exit.
	print_help: bool;

	// Module store path override.
	store: string;

	// Per-module host uri overrides.
	// FUTURE: Allow vendor to be omitted, use config if available
	host_map: Table(Module_ID, string, hash_module_id, are_module_ids_equal);

	// Per-host SSH key overrides.
	ssh_map: Table(string, string);

	// Modules to publish.
	publish: Table(Module_ID, void, hash_module_id, are_module_ids_equal);

	Compatibility :: struct {
		// Allow surrogate halves in your utf8 strings. But why?
		allow_wobbly_utf8: bool;

		// Don't skip any expressions, something else will configure that.
		do_not_skip_expressions: bool;
	}

	compatibility: Compatibility;
}

// Constructs an option key, escaping characters if necessary.
make_option_key :: (subkeys: ..string) -> string {
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
			case #char "\\"; array_add(*result, #char "\\", it);
			case; array_add(*result, it);
			}
		}
	}

	return .{ result.count, result.data };
}

#scope_module

apply_option :: (using options: *Options, key: string, value: string) -> (success: bool, message := "") {
	bool_option :: (value: string) -> bool #expand {
		if !value || equal_nocase(value, "true") return true;
		if equal_nocase(value, "false") return false;
		`return false, "only accepts values '' (true), 'true', and 'false'";
	}

    subkey_at :: (index: int) -> string #expand {
        return ifx index < `subkeys.count then `subkeys[index];
    }

    subkey_is :: (index: int, desired: string, last := false) -> bool #expand {
        if !equal_nocase(desired, subkey_at(index)) return false;
        return !last || index == `subkeys.count - 1;
    }

    success, subkeys, message := split_option_key(key);
    if !success return false, message;

	if subkey_is(0, "compatibility") {
		if subkey_is(1, "allow_wobbly_utf8", last = true) {
			options.compatibility.allow_wobbly_utf8 = bool_option(value);
            return true;
        } else if subkey_is(1, "do_not_skip_expressions", last = true) {
            options.compatibility.do_not_skip_expressions = bool_option(value);
            return true;
        }
    } else if subkey_is(0, "help", last = true) {
        options.print_help = bool_option(value);
        return true;
	} else if subkey_is(0, "host") {
        vendor := subkey_at(1);
        module := subkey_at(2);

        if !(subkeys.count == 1) && !(subkeys.count == 3 && vendor && module)
            return false, "must have form 'host' or 'host.<vendor>.<moudle>'";

		prev_host := table_find_pointer(*options.host_map, .{ vendor, module });
        if prev_host {
            free(prev_host.*);
            prev_host.* = copy_string(value);
        } else {
            table_add(
                *options.host_map,
                .{ copy_string(vendor), copy_string(module) },
                copy_string(value)
            );
        }
        return true;
	} else if subkey_is(0, "publish") {
		vendor := subkey_at(1);
		module := subkey_at(2);

		if !(subkeys.count == 3 && vendor && module)
            return false, "must have form 'publish.<vendor>.<module>'";

        if !table_contains(*options.publish, .{ vendor, module }) {
            _void: void;
            table_add(
                *options.publish,
                .{ copy_string(vendor), copy_string(module) },
                _void
            );
        }
        return true;
	} else if subkey_is(0, "ssh") {
		host := subkey_at(1);

		if !(subkeys.count == 1) && !(subkeys.count == 2 && host)
            return false, "must have form 'ssh' or 'ssh.<host>'";

        prev_host := table_find_pointer(*options.ssh_map, host);
        if prev_host {
            free(prev_host.*);
            prev_host.* = copy_string(value);
        } else {
            table_add(*options.ssh_map, copy_string(host), copy_string(value));
        }
        return true;
	} else if subkey_is(0, "store") {
		if options.store free(options.store);
		options.store = copy_string(value);
        return true;
	}

    return false, "is not recognized";
}

free_options :: (using options: Options) {
	if store free(store);

	for host_map {
		remove it;
		if it_index.module free(it_index.module);
		if it_index.vendor free(it_index.vendor);
		if it free(it);
	}
	deinit(*host_map);

	for ssh_map {
		remove it;
		if it_index free(it_index);
		if it free(it);
	}
	deinit(*ssh_map);

	for publish {
		remove it;
		if it_index.vendor free(it_index.vendor);
		if it_index.module free(it_index.module);
	}
	deinit(*publish);
}

#scope_file

// The returned data is allocated via temp.
split_option_key :: (key: string) -> (success: bool, subkeys: [] string, message: string) {
	if !key return true, .[], "";

	base: [] u8;
	base.data = talloc(key.count);
	base.count = key.count;

	subkeys: [..] string;
    subkeys.allocator = temp;

	subkey := array_add(*subkeys);
	subkey.data = base.data;

	is_escape := false;

	for key {
		if is_escape {
			is_escape = false;
			if it == {
			case #char "."; #through;
			case #char "\\";
			case; return false, .[], "Invalid key escape (must match /\\\\[.\\\\]/)";
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
		return false, .[], "Key cannot end with an unpaired escape ('\\')";

	if !subkey.count
		return false, .[], "Key cannot have an empty component";

	return true, subkeys, "";
}

#import "Basic";
#import "Hash_Table";
#import "String";
