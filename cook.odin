package cook

/* Cook */

import "base:runtime"
import "core:os"
import "core:fmt"
import "core:hash"
import "core:sort"
import "core:strings"
import "core:path/filepath"
import "core:c/libc"

File_State :: enum
{
    Not_Modified,
    Modified,
    Created,
    Deleted,
}

track_file :: proc(path: string) -> File_State
{
    _base := base(path)
    _extension := extension(path)
    _file := file(path)
    cache_path := join(_cache_directory, concatenate(_file, "_", _extension[1:]))

    if !exists(path)
    {
        if exists(cache_path)
        {
            os.remove(cache_path)
            return .Deleted
        }
        else do return .Not_Modified
    }
    
    if exists(cache_path)
    {
        cache_data := read_file_data(cache_path)
        old_file_size := (transmute(^u32)&cache_data[0])^
        old_cache_hash := (transmute(^u32)&cache_data[size_of(u32)])^

        new_file_size := cast(u32)os.file_size_from_path(path)
        new_cache_hash := hash.crc32(read_file_data(path))

        if old_cache_hash != new_cache_hash
        {
            new_cache_data := [2]u32{new_file_size, new_cache_hash}
            os.write_entire_file(cache_path, transmute([]byte)runtime.Raw_Slice{&new_cache_data, size_of(new_cache_data)})
            return .Modified
        }
    }
    else
    {
        file_size := cast(u32)os.file_size_from_path(path)
        cache_hash := hash.crc32(read_file_data(path))

        cache_data := [2]u32{file_size, cache_hash}
        os.write_entire_file(cache_path, transmute([]byte)runtime.Raw_Slice{&cache_data, size_of(cache_data)})
        return .Created
    }

    return .Not_Modified
}

read_file :: proc(path: string) -> string
{
    d, s := os.read_entire_file(path, context.temp_allocator)
    assert(s)
    return string(d)
}

read_file_data :: proc(path: string) -> []byte
{
    d, s := os.read_entire_file(path, context.temp_allocator)
    assert(s)
    return d
}

execute :: proc(args: ..any, sep := " ") -> i32
{
    sb: strings.Builder
    strings.builder_init_len_cap(&sb, 0, 2048, context.temp_allocator)
    fmt.sbprint(&sb, args = args, sep = sep)
    strings.write_byte(&sb, 0)
    return libc.system(transmute(cstring)raw_data(sb.buf))
}

concatenate :: proc(args: ..string) -> string
{
    s, e := strings.concatenate(a = args, allocator = context.temp_allocator)
    assert(e == .None)
    return s
}

remove :: proc(s, k: string, n := -1) -> string
{
    _s, _ := strings.remove(s, k, n, context.temp_allocator)
    assert(_s != "")
    return _s
}

contains :: proc(s, k: string) -> bool
{
    return strings.contains(s, k)
}

cli_flag :: proc(flag: string) -> bool
{
    _flag, error := strings.concatenate({"-", flag}, context.temp_allocator)
    assert(error == .None)
    for arg in os.args do if arg == _flag do return true
    return false
}

join :: proc(args: ..string) -> string
{
    s := filepath.join(elems = args, allocator = context.temp_allocator)
    assert(s != "")
    return s
}

cli_value :: proc(flag: string) -> (string, bool)
{
    _flag, error := strings.concatenate({"-", flag, ":"}, context.temp_allocator)
    assert(error == .None)
    for arg in os.args do if strings.contains(arg, _flag) do return arg[strings.index(arg, ":") + 1:], true
    return "", false
}

cli_pair :: proc(flag, key: string) -> (string, bool)
{
    _flag, error := strings.concatenate({"-", flag, ":", key, "="}, context.temp_allocator)
    assert(error == .None)
    for arg in os.args do if strings.contains(arg, _flag) do return arg[strings.index(arg, "=") + 1:], true
    return "", false
}

current_directory :: proc() -> string
{
    s := os.get_current_directory(context.temp_allocator)
    assert(s != "")
    return s
}

work_directory :: proc() -> string
{
    if path, has := cli_value("work-directory"); has do return join(current_directory(), path)
    return current_directory()
}

cache_directory :: proc() -> string
{
    return join(work_directory(), ".cook")
}

cook_odin_path :: proc() -> string
{
    return join(work_directory(), "cook.odin")
}

cook_odin_executable_path :: proc() -> string
{
    return join(cache_directory(), "cook.exe")
}

absolute :: proc(path: string) -> string
{
    s, e := filepath.abs(path, context.temp_allocator)
    assert(s != "")
    return s
}

exists :: os.exists
is_directory :: os.is_dir
is_file :: os.is_file
extension :: filepath.ext
base :: filepath.base

file :: proc(path: string) -> string
{
    _base := base(path)
    _extension := extension(_base)[1:]
    return _base[:len(_base) - len(_extension) - 1]
}

_repos: map[string]string

Rule_Filter_Proc :: #type proc(repo, path: string) -> bool

Rule_Filter :: struct
{
    repo: string,
    procedure: Rule_Filter_Proc,
}

Rule_Output_Proc :: #type proc(repo, path: string) -> string
Rule_Command_Proc :: #type proc(repo, input, output: string) -> bool

Rule :: struct
{
    priority: int,
    filters: []Rule_Filter,
    output: Rule_Output_Proc,
    command: Rule_Command_Proc,
}

Action_Command :: #type proc()

Action :: struct
{
    priority: int,
    trigger: string,
    command: Action_Command,
}

action_execute :: proc(action: Action)
{
    if _verbose do fmt.println("ACTION:", action)
    if !cli_flag(action.trigger) do return 
    action.command()
}

Job :: union
{
    Rule,
    Action,
}

_jobs: map[string]Job

cook :: proc()
{
    jobs: [dynamic]Job
    for job_name, job in _jobs do append(&jobs, job)

    jobs_interface := sort.Interface{
        collection = &jobs,
        len = proc(it: sort.Interface) -> int {
            jobs := (^[dynamic]Job)(it.collection)
            return len(jobs)
        },
        less = proc(it: sort.Interface, i, j: int) -> bool {
            jobs := (^[dynamic]Job)(it.collection)
            i_p, j_p: int
            switch _job in jobs[i] { case Rule: i_p = _job.priority; case Action: i_p = _job.priority}
            switch _job in jobs[j] { case Rule: j_p = _job.priority; case Action: j_p = _job.priority}
            return i_p < j_p
        },
        swap = proc(it: sort.Interface, i, j: int) {
            jobs := (^[dynamic]Job)(it.collection)
            i_job := jobs[i]
            j_job := jobs[j]
            jobs[i] = j_job
            jobs[j] = i_job
        },
    }

    sort.sort(jobs_interface)

    for job in jobs
    {
        switch _job in job
        {
            case Rule: rule_execute(_job)
            case Action: action_execute(_job)
        }
    }
}

rule_execute :: proc(rule: Rule)
{
    filter_execute_recursive :: proc(rule: Rule, filter: Rule_Filter, directory_path: string)
    {
        directory_handle, open_directory_error := os.open(directory_path)
        if open_directory_error != os.ERROR_NONE do return
        defer os.close(directory_handle)

        entries, read_directory_error := os.read_dir(directory_handle, 1024, context.temp_allocator)
        if read_directory_error != os.ERROR_NONE do return

        for entry in entries
        {
            if entry.is_dir
            {
                filter_execute_recursive(rule, filter, entry.fullpath)
            }
            else
            {
                if !filter.procedure(filter.repo, entry.fullpath) do continue
                
                output := rule.output(filter.repo, entry.fullpath)
                state := track_file(entry.fullpath)
                if !os.is_file(output) || state == .Created || state == .Modified
                {
                    rule.command(filter.repo, entry.fullpath, output)
                }
            }
        }
    }

    for filter in rule.filters
    {
        repo_path := join(work_directory(), _repos[filter.repo])
        if !os.is_dir(repo_path) do continue

        filter_execute_recursive(rule, filter, repo_path)
    }
}

_verbose: bool
_cache_directory: string
_cook_odin_path: string
_cook_odin_executable_path: string

@(init)
_init :: proc()
{
    _verbose = cli_flag("verbose")
    _cache_directory = cache_directory()
    _cook_odin_path = cook_odin_path()
    _cook_odin_executable_path = cook_odin_executable_path()
}