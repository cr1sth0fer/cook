package cook

import "base:runtime"
import "core:os"
import "core:fmt"
import "core:hash"
import "core:sort"
import "core:time"
import "core:thread"
import "core:c/libc"
import "core:strings"
import "core:path/filepath"

verbose: bool
show_timings: bool
current_directory: string
work_directory: string
cache_directory: string
cook_odin_source_path: string
cook_odin_executable_path: string

@(init)
cook_init :: proc()
{
    verbose = cli_flag("verbose")
    show_timings = cli_flag("show-timings")
    current_directory = os.get_current_directory(context.temp_allocator)
    if path, has := cli_value("work-directory"); has do work_directory = join(current_directory, path)
    else do work_directory = current_directory
    cache_directory = join(work_directory, "cook")
    cook_odin_source_path = join(work_directory, "cook.odin")
    cook_odin_executable_path = join(cache_directory, "cook.exe")
}

@(private)
File_State_Info :: struct
{
    done_jobs,
    total_jobs: int,
}

@(private)
file_state_map: map[File_State]File_State_Info

@(private)
file_state_info :: proc(s: File_State, done: bool)
{
    info, info_ok := file_state_map[s]
    if done do info.done_jobs += 1
    info.total_jobs += 1
    file_state_map[s] = info
}

Rule :: struct($T: typeid)
{
    priority: int,
    collect: proc() -> []T,
    input: proc(^T) -> string,
    output: proc(^T) -> string,
    execute: proc(^T, string, string) -> bool,
}

@(private)
Raw_Rule :: struct
{
    priority: int,
    type_size: int,
    collect: proc() -> runtime.Raw_Slice,
    input: proc(rawptr) -> string,
    output: proc(rawptr) -> string,
    execute: proc(rawptr, string, string) -> bool,
}

@(private)
job_rule :: proc(rule: Rule($T))
{
    append(&jobs, Raw_Rule{
        priority = rule.priority,
        type_size = size_of(T),
        collect = auto_cast rule.collect,
        input = auto_cast rule.input,
        output = auto_cast rule.output,
        execute = auto_cast rule.execute,
    })
}

@(private)
raw_rule_execute :: proc(rule: Raw_Rule)
{
    c := rule.collect()
    for i in 0..<c.len
    {
        e := rawptr(uintptr(c.data) + uintptr(rule.type_size * i))
        input := rule.input(e)
        output := rule.output(e)

        fs_if: if _fs := track_file(input); _fs == nil
        {
            if exists(output) do break fs_if
            done := rule.execute(e, input, output) && exists(output)
            if !done do fmt.println("failed to generate", output)
        }
        else do switch file_state in _fs
        {
            case File_Created:
                done := rule.execute(e, input, output) && exists(output)
                if !done do fmt.println("failed to generate", output)
                file_state_info(file_state, done)

            case File_Modified:
                done := rule.execute(e, input, output) && exists(output)
                if !done do fmt.println("failed to generate", output)
                file_state_info(file_state, done)

            case File_Deleted:
                os.remove(file_state.path)
        }
    }
}

Pack :: struct($T: typeid)
{
    priority: int,
    collect: proc() -> []T,
    input: proc(^T) -> string,
    output: proc([]T) -> string,
    execute: proc([]T, []string, string) -> bool,
}

@(private)
Raw_Pack :: struct
{
    priority: int,
    type_size: int,
    collect: proc() -> runtime.Raw_Slice,
    input: proc(rawptr) -> string,
    output: proc(runtime.Raw_Slice) -> string,
    execute: proc(runtime.Raw_Slice, []string, string) -> bool,
}

@(private)
job_pack :: proc(u: Pack($T))
{
    append(&jobs, Raw_Pack{
        priority = rule.priority,
        type_size = size_of(T),
        collect = auto_cast rule.collect,
        input = auto_cast rule.input,
        output = auto_cast rule.output,
        execute = auto_cast rule.execute,
    })
}

@(private)
raw_pack_execute :: proc(pack: Raw_Pack)
{
    c := pack.collect()
    output := pack.output(c)
    i_ds: [dynamic]string 
    fs_ds: [dynamic]File_State
    for i in 0..<c.len
    {
        e := rawptr(uintptr(c.data) + uintptr(pack.type_size * i))
        input := pack.input(e)
        append(&i_ds, input)
        if _fs := track_file(input); _fs != nil do append(&fs_ds, _fs)
    }

    if !exists(output) || len(fs_ds) > 0
    {
        done := pack.execute(c, i_ds[:], output) && exists(output)
        if !done do fmt.println("failed to generate", output)
        for fs in fs_ds do file_state_info(fs, done)
    }
}

Unpack :: struct($T: typeid)
{
    priority: int,
    collect: proc() -> []T,
    input: proc(^T) -> string,
    output: proc(^T) -> []string,
    execute: proc(^T, string, []string) -> bool,
}

@(private)
Raw_Unpack :: struct
{
    priority: int,
    type_size: int,
    collect: proc() -> runtime.Raw_Slice,
    input: proc(rawptr) -> string,
    output: proc(rawptr) -> []string,
    execute: proc(rawptr, string, []string) -> bool,
}

@(private)
job_unpack :: proc(u: Unpack($T))
{
    append(&jobs, Raw_Unpack{
        priority = rule.priority,
        type_size = size_of(T),
        collect = auto_cast rule.collect,
        input = auto_cast rule.input,
        output = auto_cast rule.output,
        execute = auto_cast rule.execute,
    })
}

@(private)
raw_unpack_execute :: proc(unpack: Raw_Unpack)
{
    c := unpack.collect()
    for i in 0..<c.len
    {
        e := rawptr(uintptr(c.data) + uintptr(unpack.type_size * i))
        input := unpack.input(e)
        output := unpack.output(e)

        if _fs := track_file(input); _fs == nil
        {
            execute: bool
            for o in output do if !exists(o)
            {
                execute = true
                break
            }
            if execute do unpack.execute(e, input, output)
            for o in output do if !exists(o) do fmt.println("failed to generate", o)
        }
        else do switch file_state in _fs
        {
            case File_Created:
                done := unpack.execute(e, input, output)
                for o in output
                {
                    fmt.println("failed to generate", o)
                    file_state_info(file_state, done && exists(o))
                }

            case File_Modified:
                done := unpack.execute(e, input, output)
                for o in output
                {
                    fmt.println("failed to generate", o)
                    file_state_info(file_state, done && exists(o))
                }

            case File_Deleted:
                os.remove(file_state.path)
        }
    }
}

Action :: struct
{
    priority: int,
    trigger: string,
    execute: proc(),
}

@(private)
job_action :: proc(r: Action)
{
    append(&jobs, r)
}

@(private)
action_execute :: proc(action: Action)
{
    if !cli_flag(action.trigger) do return 
    action.execute()
}

Require :: struct
{
    priority: int,
    check: proc() -> bool,
    execute: proc(),
}

@(private)
job_require :: proc(r: Require)
{
    append(&jobs, r)
}

@(private)
require_execute :: proc(require: Require)
{
    if !require.check() do require.execute()
}

@(private)
Job :: union #no_nil
{
    Raw_Rule,
    Raw_Pack,
    Raw_Unpack,
    Action,
    Require,
}

@(private)
jobs: [dynamic]Job

job :: proc{
    job_rule,
    job_pack,
    job_unpack,
    job_action,
    job_require,
}

// Alias for ```os.exists```
exists :: os.exists

// Alias for ```os.is_dir```
is_dir :: os.is_dir

// Alias for ```os.is_file```
is_file :: os.is_file

// Alias for ```filepath.ext```
ext :: filepath.ext

// Alias for ```filepath.base```
base :: filepath.base

// Alias for ```filepath.abs```
abs :: proc(path: string) -> string
{
    s, e := filepath.abs(path, context.temp_allocator)
    return s
}

// Returns file base without the extenstion
// - 'path/to/file.txt' returns 'file'
file :: proc(path: string) -> string
{
    _base := base(path)
    _extension := ext(_base)[1:]
    return _base[:len(_base) - len(_extension) - 1]
}

// Alias for ```filepath.join```
join :: proc(args: ..string) -> string
{
    return filepath.join(elems = args, allocator = context.temp_allocator)
}

// Alias for ```strings.clone```
clone :: proc(s: string) -> string
{
    s, e := strings.clone(s, allocator = context.temp_allocator)
    return s
}

// Alias for ```strings.concatenate```
concatenate :: proc(args: ..string) -> string
{
    s, e := strings.concatenate(a = args, allocator = context.temp_allocator)
    return s
}

// Alias for ```strings.remove```
remove :: proc(s, k: string, n := -1) -> string
{
    _s, _ := strings.remove(s, k, n, context.temp_allocator)
    return _s
}

// Alias for ```strings.contains```
contains :: strings.contains

// Perfoms system execution using ```core:c/libc.system```
execute :: proc(args: ..any, sep := " ") -> i32
{
    sb: strings.Builder
    strings.builder_init_len_cap(&sb, 0, 4096, context.temp_allocator)
    fmt.sbprint(&sb, args = args, sep = sep)
    strings.write_byte(&sb, 0)
    return libc.system(transmute(cstring)raw_data(sb.buf))
}

cli_flag :: proc(flag: string) -> bool
{
    _flag, error := strings.concatenate({"-", flag}, context.temp_allocator)
    assert(error == .None)
    for arg in os.args do if arg == _flag do return true
    return false
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

@(private)
hash_load :: proc(path: string) -> u32
{
    data, data_ok := os.read_entire_file(path, context.temp_allocator)
    return ((^u32)(raw_data(data)))^
}

@(private)
hash_save :: proc(path: string, h: u32)
{
    h := h
    os.write_entire_file(path, transmute([]byte)runtime.Raw_Slice{&h, size_of(u32)}, false)
}

@(private)
File_Created :: struct
{
    path: string,
    hash: u32,
}

@(private)
File_Deleted :: struct
{
    path: string,
    hash: u32,
}

@(private)
File_Modified :: struct
{
    path: string,
    hash: u32,
}

@(private)
File_State :: union
{
    File_Created,
    File_Deleted,
    File_Modified,
}

@(private)
track_file :: proc(path: string) -> File_State
{
    _base := base(path)
    _extension := ext(path)
    _file := file(path)
    hash_path := join(cache_directory, concatenate(_file, "_", _extension[1:]))

    // File dont exists
    if !exists(path)
    {
        // File dont exists, but the hash file exists, this means that file was deleted
        if exists(hash_path) do return File_Deleted{hash_path, hash_load(hash_path)}
        else do return nil // File and hash file dont exists, so nothing changed
    }
    
    // File and hash file exists, so the file can only be modified
    if exists(hash_path)
    {
        data, _ := os.read_entire_file(path, context.temp_allocator)
        new_hash := hash.murmur32(data)
        old_hash := hash_load(hash_path)
        if old_hash != new_hash do return File_Modified{hash_path, new_hash}
    }
    else // File exists but hash file dont, so the file was created
    {
        data, _ := os.read_entire_file(path, context.temp_allocator)
        _hash := hash.murmur32(data)
        return File_Created{hash_path, _hash}
    }

    // No modification at all
    return nil
}

cook :: proc()
{
    t0 := time.now()

    jobs_interface := sort.Interface{
        collection = &jobs,
        len = proc(it: sort.Interface) -> int {
            jobs := (^[dynamic]Job)(it.collection)
            return len(jobs)
        },
        less = proc(it: sort.Interface, i, j: int) -> bool {
            jobs := (^[dynamic]Job)(it.collection)
            i_p, j_p: int
            switch _job in jobs[i]
            {
                case Raw_Rule: i_p = _job.priority;
                case Raw_Pack: i_p = _job.priority;
                case Raw_Unpack: i_p = _job.priority;
                case Action: i_p = _job.priority;
                case Require: i_p = _job.priority;
            }
            switch _job in jobs[j]
            {
                case Raw_Rule: j_p = _job.priority;
                case Raw_Pack: j_p = _job.priority;
                case Raw_Unpack: j_p = _job.priority;
                case Action: j_p = _job.priority;
                case Require: j_p = _job.priority;
            }
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

    pool: thread.Pool
    thread.pool_init(&pool, context.allocator, os.processor_core_count())
    thread.pool_start(&pool)
    current_priority: int = min(int)
    for job, i in jobs
    {
        priority := job_priority(job)
        if priority == current_priority
        {
            thread.pool_add_task(&pool, context.allocator, job_task, nil, i)
        }
        else
        {
            thread.pool_join(&pool)
            current_priority = priority
            thread.pool_add_task(&pool, context.allocator, job_task, nil, i)
        }
    }

    thread.pool_finish(&pool)
    thread.pool_destroy(&pool)

    for _fs, fs_info in file_state_map do switch file_state in _fs
    {
        case File_Created:
            if fs_info.done_jobs == fs_info.total_jobs do hash_save(file_state.path, file_state.hash)
            fmt.println(file_state, fs_info)

        case File_Deleted:
            os.remove(file_state.path)

        case File_Modified:
            if fs_info.done_jobs == fs_info.total_jobs do hash_save(file_state.path, file_state.hash)
            fmt.println(file_state, fs_info)
    }

    if show_timings
    {
        t1 := time.now()
        ms := time.duration_microseconds(time.diff(t0, t1))
        fmt.println("cooked in", ms, "ms")
    }
}

@(private)
job_priority :: proc(j: Job) -> int
{
    switch job in j
    {
        case Raw_Rule: return job.priority
        case Raw_Pack: return job.priority
        case Raw_Unpack: return job.priority
        case Action: return job.priority
        case Require: return job.priority
    }
    return 0
}

@(private)
job_task :: proc(task: thread.Task)
{
    switch _job in jobs[task.user_index]
    {
        case Raw_Rule: raw_rule_execute(_job)
        case Raw_Pack: raw_pack_execute(_job)
        case Raw_Unpack: raw_unpack_execute(_job)
        case Action: action_execute(_job)
        case Require: require_execute(_job)
    }
}