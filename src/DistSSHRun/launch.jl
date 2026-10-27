# Shared worker / go-slot launch: pin the real binary, restrict LOAD_PATH,
# unset JULIA_PROJECT so it cannot override `--project=`, and record overrides.

const _LAUNCH_UNSET_ENV = (
    "JULIA_PROJECT",
    "JULIA_NUM_THREADS",
    "JULIA_NUM_GC_THREADS",
    "OPENBLAS_NUM_THREADS",
    "GOTO_NUM_THREADS",
    "OMP_NUM_THREADS",
    "MKL_NUM_THREADS",
    "VECLIB_MAXIMUM_THREADS",
)
const _LAUNCH_LOAD_PATH = "@:@stdlib"

function worker_load_path(; ssh::Bool = false)::String
    ssh && return _LAUNCH_LOAD_PATH
    d = pkgdir(@__MODULE__)
    (d === nothing || isempty(d)) && return _LAUNCH_LOAD_PATH
    return string(_LAUNCH_LOAD_PATH, ":", d)
end

function _env_unset_prefix()::String
    parts = String["env"]
    for k in _LAUNCH_UNSET_ENV
        push!(parts, "-u", String(k))
    end
    push!(parts, "-u", "JULIA_LOAD_PATH")
    return join(parts, " ")
end
const _PINNED_JULIA = Dict{String, String}()

function _launch_thread_spec()::String
    n = Threads.nthreads()
    ni = try
        Threads.nthreads(:interactive)
    catch
        0
    end
    return ni > 0 ? "$(n),$(ni)" : string(n)
end

function _launch_opt_level_flag()::Union{Nothing, String}
    n = try
        Int(Base.JLOptions().opt_level)
    catch
        return nothing
    end
    n < 0 && return nothing
    return "-O$(n)"
end

function _launch_check_bounds_flag()::Union{Nothing, String}
    n = try
        Int(Base.JLOptions().check_bounds)
    catch
        return nothing
    end
    n == 1 && return "--check-bounds=yes"
    n == 2 && return "--check-bounds=no"
    return nothing
end

function _launch_cpu_target()::Union{Nothing, String}
    raw = try
        unsafe_string(Base.JLOptions().cpu_target)
    catch
        return nothing
    end
    s = strip(raw)
    (isempty(s) || s == "native") && return nothing
    return s
end

function _launch_blas_threads()::String
    for (pkg, mod) in Base.loaded_modules
        pkg.name == "LinearAlgebra" || continue
        try
            return string(mod.BLAS.get_num_threads())
        catch
            return "1"
        end
    end
    return "1"
end

"""Flags every worker / go slot gets (`--project=` plus pin flags)."""
function worker_exeflag_strings(
        project::AbstractString;
        local_cpu::Bool = false,
        job_id::Union{Nothing, AbstractString} = nothing,
    )::Vector{String}
    flags = String[
        "--project=$(project)",
        "--startup-file=no",
        "--history-file=no",
        "--threads=$(_launch_thread_spec())",
    ]
    opt = _launch_opt_level_flag()
    opt === nothing || push!(flags, opt)
    cb = _launch_check_bounds_flag()
    cb === nothing || push!(flags, cb)
    if local_cpu
        cpu = _launch_cpu_target()
        cpu === nothing || push!(flags, "-C$(cpu)")
    end
    if job_id !== nothing
        push!(flags, kit_job_eval_arg(String(job_id)))
    end
    return flags
end

function _drive_worker_exeflags(project::AbstractString)
    return Cmd(worker_exeflag_strings(project; local_cpu = false, job_id = resolved_kit_job_id()))
end

"""Env pairs for workers. `JULIA_PROJECT` matches `--project=` so LocalManager does not copy the parent."""
function worker_env_pairs(
        project::AbstractString;
        ssh::Bool = false,
        extra::AbstractVector{<:Pair{<:AbstractString, <:AbstractString}} = Pair{String, String}[],
    )
    n = Threads.nthreads()
    pairs = Pair{String, String}[
        "JULIA_PROJECT" => String(project),
        "JULIA_LOAD_PATH" => worker_load_path(; ssh = ssh),
        "JULIA_NUM_THREADS" => string(n),
        "OPENBLAS_NUM_THREADS" => _launch_blas_threads(),
        "OMP_NUM_THREADS" => _launch_blas_threads(),
    ]
    id = resolved_kit_job_id()
    id === nothing || push!(pairs, "DISTSSHKIT_JOB_ID" => id)
    for p in extra
        push!(pairs, String(first(p)) => String(last(p)))
    end
    return pairs
end

function _drive_worker_env(project::AbstractString)
    return worker_env_pairs(project)
end

function launch_override_names(ambient)::Vector{String}
    names = String[]
    for k in _LAUNCH_UNSET_ENV
        v = get(ambient, k, nothing)
        (v isa AbstractString && !isempty(strip(v))) && push!(names, k)
    end
    lp = get(ambient, "JULIA_LOAD_PATH", nothing)
    if lp isa AbstractString && !isempty(strip(lp)) && strip(lp) != _LAUNCH_LOAD_PATH
        push!(names, "JULIA_LOAD_PATH")
    end
    return unique!(names)
end

function launch_override_notice(host::AbstractString, names::AbstractVector{<:AbstractString})::String
    isempty(names) && return ""
    return string(host, ": launch overrides ", join(names, ", "))
end

function pin_local_julia(spec::Union{Nothing, AbstractString} = nothing)::String
    starter = resolve_controller_julia(spec)
    key = "local\0$(starter)"
    cached = get(_PINNED_JULIA, key, nothing)
    cached isa String && return cached
    out = strip(read(`$(starter) --startup-file=no -e 'print(joinpath(Sys.BINDIR, "julia"))'`, String))
    isempty(out) && return starter
    _PINNED_JULIA[key] = String(out)
    return String(out)
end

function pin_remote_julia(
        host::AbstractString,
        spec::Union{Nothing, AbstractString} = nothing,
    )::Union{Nothing, String}
    h = String(host)
    starter = resolve_remote_julia(h, spec)
    starter === nothing && return nothing
    key = h * "\0" * starter
    cached = get(_PINNED_JULIA, key, nothing)
    cached isa String && return cached
    pq = _remote_julia_path_sh(starter)
    inner = string(pq, " --startup-file=no -e 'print(joinpath(Sys.BINDIR, \"julia\"))'")
    code, out = _remote_shell_status(h, inner)
    code == 0 || return starter
    p = strip(out)
    isempty(p) && return starter
    _PINNED_JULIA[key] = String(p)
    return String(p)
end

function ssh_worker_exename(julia_path::AbstractString)::Cmd
    argv = String["env"]
    for k in _LAUNCH_UNSET_ENV
        push!(argv, "-u", String(k))
    end
    push!(argv, "-u", "JULIA_LOAD_PATH")
    push!(argv, String(julia_path))
    return Cmd(argv)
end

function ssh_addprocs_bind_localhost(host::AbstractString)::String
    return string(ssh_addprocs_machine(host), " 127.0.0.1")
end

function ssh_tunnel_enabled()::Bool
    return get(ENV, "DISTSSHKIT_SSH_TUNNEL", "1") != "0"
end

"""Random per-run cookie before the first worker. Never log the value."""
function ensure_run_cluster_cookie!()::Nothing
    nprocs() > 1 && return nothing
    alphabet = ['0':'9'; 'A':'Z'; 'a':'z']
    Distributed.cluster_cookie(String(rand(alphabet, 16)))
    return nothing
end

function _precompile_worker_project!(wid::Int)
    try
        remotecall_wait(wid) do
            Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
            mod = Base.loaded_modules[
                Base.PkgId(
                    Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"),
                    "Pkg",
                ),
            ]
            mod.precompile(; io = devnull)
            return nothing
        end
    catch
    end
    return nothing
end

function go_slot_julia_argv(
        julia_bin::AbstractString,
        project::AbstractString,
        script::AbstractString,
        script_args;
        local_cpu::Bool = true,
        extra_L::AbstractVector{<:AbstractString} = String[],
    )::Vector{String}
    argv = String[String(julia_bin)]
    append!(argv, worker_exeflag_strings(project; local_cpu = local_cpu))
    for p in extra_L
        push!(argv, "-L", String(p))
    end
    push!(argv, String(script))
    append!(argv, collect(String, script_args))
    return argv
end

function _add_local_drive_workers!(n::Int, project::AbstractString, julia_bin::AbstractString)
    n < 1 && return nothing
    flags = Cmd(worker_exeflag_strings(project; local_cpu = true, job_id = resolved_kit_job_id()))
    env = worker_env_pairs(project)
    addprocs(
        1;
        exename = julia_bin,
        exeflags = flags,
        env = env,
        topology = :master_worker,
    )
    _precompile_worker_project!(last(workers()))
    rest = n - 1
    rest < 1 && return nothing
    addprocs(
        rest;
        exename = julia_bin,
        exeflags = flags,
        env = env,
        topology = :master_worker,
    )
    return nothing
end

function _add_ssh_drive_workers!(
        machine::AbstractString,
        n::Int,
        julia_bin::AbstractString,
        project::AbstractString,
        sshflags::Cmd,
    )
    n < 1 && return nothing
    flags = Cmd(worker_exeflag_strings(project; local_cpu = false, job_id = resolved_kit_job_id()))
    env = worker_env_pairs(project; ssh = true)
    exename = ssh_worker_exename(julia_bin)
    addprocs(
        [(machine, 1)];
        exename = exename,
        sshflags = sshflags,
        dir = project,
        tunnel = ssh_tunnel_enabled(),
        cmdline_cookie = false,
        exeflags = flags,
        env = env,
        topology = :master_worker,
    )
    _precompile_worker_project!(last(workers()))
    rest = n - 1
    rest < 1 && return nothing
    addprocs(
        [(machine, rest)];
        exename = exename,
        sshflags = sshflags,
        dir = project,
        tunnel = ssh_tunnel_enabled(),
        cmdline_cookie = false,
        exeflags = flags,
        env = env,
        topology = :master_worker,
    )
    return nothing
end

function go_remote_julia_prefix(julia_bin::AbstractString)::String
    jb = _remote_shell_path_word(julia_bin)
    flags = worker_exeflag_strings("."; local_cpu = false)
    flag_s = sprint() do io
        for f in flags
            print(io, ' ', posix_quote(f))
        end
    end
    return "$(_env_unset_prefix()) JULIA_LOAD_PATH=$(posix_quote(_LAUNCH_LOAD_PATH)) $(jb)$(flag_s)"
end
