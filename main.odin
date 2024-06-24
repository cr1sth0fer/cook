package cook

import "base:runtime"
import "core:os"
import "core:fmt"
import "core:hash"
import "core:strings"
import "core:path/filepath"
import "core:c/libc"
import "core:sort"

_cook_code := #load("cook.odin", string)

main :: proc()
{
    if !os.exists(_cook_odin_path) do return
    if !os.is_dir(_cache_directory) do os.make_directory(_cache_directory)

    cook_odin_data := read_file(_cook_odin_path)
    cook_code := remove(_cook_code, "package cook")
    if !contains(cook_odin_data, cook_code)
    {
        all_code := concatenate(cook_odin_data, cook_code)
        os.write_entire_file(_cook_odin_path, transmute([]byte)all_code)
    }

    state := track_file(_cook_odin_path)
    if state == .Created || state == .Modified || !os.is_file(_cook_odin_executable_path)
    {
        execute(args = {"odin build ", _cook_odin_path, " -file -o:speed -out:", _cook_odin_executable_path}, sep = "")
    }

    sb, sb_error := strings.builder_make_len_cap(0, 512, context.temp_allocator)
    assert(sb_error == .None)
    strings.write_string(&sb, _cook_odin_executable_path)
    strings.write_string(&sb, " ")
    for arg in os.args[1:] { strings.write_string(&sb, arg); strings.write_string(&sb, " ") }
    execute(strings.to_string(sb))
}