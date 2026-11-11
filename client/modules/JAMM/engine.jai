#scope_module

// modules_path is allocated regardless of success
initialize_store :: (
    store: string,
    cwd := ""
) -> (success: bool, modules_path: string, message := "") {
	modules_path := trim_slash(store);

	if !modules_path then modules_path = get_default_store_path();
    if !modules_path {
        log(
            "Could not find a module store location. Defaulting to the current directory.\n",
            flags = .WARNING
        );
    }

	#if OS == .WINDOWS
		path_overwrite_separators(modules_path, #char "/");

	if !is_absolute_path(modules_path) {
        working_directory := ifx cwd then trim_slash(cwd) else get_normalized_cwd(,, temp);
		modules_path = tprint("%/%", working_directory, modules_path);
    }

	modules_path = sprint("%/modules", modules_path);

	os_path := modules_path;
	#if OS == .WINDOWS {
		os_path = copy_string(os_path,, temp);
		path_overwrite_separators(os_path, #char "\\");
	}
	is_dir, success := is_directory(os_path);

	if success {
		if !is_dir {
            return false, modules_path, "exists, but is not a directory";
        }
	} else {
		log(
			"Could not find a module store at '%'. Creating '%'...\n",
			store,
            modules_path,
			flags = .WARNING
		);
		if !make_directory_if_it_does_not_exist(modules_path, recursive = true) {
			return false, modules_path, "was not able to be created";
        }
	}

    return true, modules_path;
}

#scope_file

#import "File";
#import "File_Utilities";
