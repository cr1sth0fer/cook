package cook

import "core:os"
import "core:fmt"
import "core:strings"

when #config(COOKER, false)
{
    code_hash := #load_hash("cook.odin", "murmur32")
    cook_code := #load("cook.odin", []byte)

    main :: proc()
    {
        if !exists(cook_odin_source_path)
        {
            if verbose do fmt.println("no cook.odin found in", work_directory)
            return
        }

        if !is_dir(cache_directory) do os.make_directory(cache_directory)

        cook_code_path := join(cache_directory, "cook.odin")
        if !is_file(cook_code_path) do os.write_entire_file(cook_code_path, cook_code)

        _fs_if: if _fs := track_file(cook_odin_source_path); _fs == nil
        {
            if !cli_flag("build-cook") do break _fs_if
            os.write_entire_file(cook_code_path, cook_code)
            execute(args = {"odin build ", cook_odin_source_path, " -file -o:speed -out:", cook_odin_executable_path}, sep = "")
            if exists(cook_odin_executable_path) 
            {
                if verbose do fmt.println("built cook.odin")
            }
            else do return
        }
        else do #partial switch file_state in _fs
        {
            case File_Created:
                os.write_entire_file(cook_code_path, cook_code)
                execute(args = {"odin build ", cook_odin_source_path, " -file -o:speed -out:", cook_odin_executable_path}, sep = "")
                if exists(cook_odin_executable_path)
                {
                    hash_save(file_state.path, file_state.hash)
                    if verbose do fmt.println("built cook.odin")
                }
                else do return

            case File_Modified:
                os.write_entire_file(cook_code_path, cook_code)
                execute(args = {"odin build ", cook_odin_source_path, " -file -o:speed -out:", cook_odin_executable_path}, sep = "")
                if exists(cook_odin_executable_path)
                {
                    hash_save(file_state.path, file_state.hash)
                    if verbose do fmt.println("built cook.odin")
                }
                else do return
        }

        sb, sb_error := strings.builder_make_len_cap(0, 2048, context.temp_allocator)
        assert(sb_error == .None)
        strings.write_string(&sb, cook_odin_executable_path)
        strings.write_string(&sb, " ")
        for arg in os.args[1:] { strings.write_string(&sb, arg); strings.write_string(&sb, " ") }
        execute(strings.to_string(sb))
    }
}