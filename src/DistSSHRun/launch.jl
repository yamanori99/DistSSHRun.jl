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
    extras = String[]
    ap = Base.active_project()
    if ap !== nothing
        pd = dirname(String(ap))
        isempty(pd) || push!(extras, pd)
    end
    d = pkgdir(@__MODULE__)
    if d !== nothing && !isempty(d) && !(d in extras)
        push!(extras, d)
    end
    isempty(extras) && return _LAUNCH_LOAD_PATH
    return string(_LAUNCH_LOAD_PATH, ":", join(extras, ":"))
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

const _JOB_SEED = Ref{Union{Nothing, UInt64}}(nothing)
const _NEXT_WORKER_RANK = Ref(1)
const _ASSIGNED_RANKS = Int[]
const _NEXT_PMAP_CALL = Ref(1)
const _ITEM_MAP = Dict{Tuple{Int, Int}, Int}()
const _ITEM_LOCK = ReentrantLock()

"""One seed for this run. `DISTSSHKIT_JOB_SEED` wins when it is a `UInt64`."""
function job_seed()::UInt64
    existing = _JOB_SEED[]
    existing !== nothing && return existing
    parsed = tryparse(UInt64, strip(get(ENV, "DISTSSHKIT_JOB_SEED", "")))
    seed = parsed === nothing ? rand(UInt64) : parsed
    _JOB_SEED[] = seed
    return seed
end

"""Stable worker seed from the job seed and a launch rank. Does not read `myid()`."""
function worker_seed(job::Integer, rank::Integer)::UInt64
    rank >= 1 || throw(ArgumentError("worker rank must be ≥ 1, got $rank"))
    x = xor(UInt64(job), UInt64(rank) * 0x9E3779B97F4A7C15)
    x = xor(x, x >> 30) * 0xBF58476D1CE4E5B9
    x = xor(x, x >> 27) * 0x94D049BB133111EB
    return xor(x, x >> 31)
end

function take_worker_rank()::Int
    rank = _NEXT_WORKER_RANK[]
    _NEXT_WORKER_RANK[] = rank + 1
    push!(_ASSIGNED_RANKS, rank)
    return rank
end

function reset_worker_seeds!()
    _JOB_SEED[] = nothing
    _NEXT_WORKER_RANK[] = 1
    empty!(_ASSIGNED_RANKS)
    lock(_ITEM_LOCK) do
        _NEXT_PMAP_CALL[] = 1
        empty!(_ITEM_MAP)
    end
    return nothing
end

"""One id per `worker_pmap` call, taken on process 1 before `pmap` starts."""
function _take_pmap_call()::Int
    return lock(_ITEM_LOCK) do
        call = _NEXT_PMAP_CALL[]
        _NEXT_PMAP_CALL[] = call + 1
        return call
    end
end

function _note_item!(call::Integer, item::Integer, rank::Integer)
    lock(_ITEM_LOCK) do
        _ITEM_MAP[(Int(call), Int(item))] = Int(rank)
    end
    return nothing
end

"""`DISTSSHKIT_BLAS_THREADS` when the operator set it, else `nothing`."""
function _explicit_blas_threads()::Union{Nothing, String}
    raw = strip(get(ENV, "DISTSSHKIT_BLAS_THREADS", ""))
    isempty(raw) && return nothing
    return raw
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
        rank::Union{Nothing, Integer} = nothing,
    )
    n = Threads.nthreads()
    pairs = Pair{String, String}[
        "JULIA_PROJECT" => String(project),
        "JULIA_LOAD_PATH" => worker_load_path(; ssh = ssh),
        "JULIA_NUM_THREADS" => string(n),
    ]
    blas = _explicit_blas_threads()
    if blas !== nothing
        push!(pairs, "OPENBLAS_NUM_THREADS" => blas)
        push!(pairs, "OMP_NUM_THREADS" => blas)
    end
    if rank !== nothing
        seed = job_seed()
        r = Int(rank)
        push!(pairs, "DISTSSHKIT_JOB_SEED" => string(seed))
        push!(pairs, "DISTSSHKIT_WORKER_RANK" => string(r))
        push!(pairs, "DISTSSHKIT_WORKER_SEED" => string(worker_seed(seed, r)))
    end
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
    code == 0 || throw(
        ArgumentError("could not resolve the remote Julia executable on $(h)"),
    )
    p = strip(out)
    isempty(p) && throw(
        ArgumentError("could not resolve the remote Julia executable on $(h)"),
    )
    _PINNED_JULIA[key] = String(p)
    return String(p)
end

function ssh_worker_exename(julia_path::AbstractString)::Cmd
    argv = String["env"]
    for k in _LAUNCH_UNSET_ENV
        push!(argv, "-u", String(k))
    end
    # Set LOAD_PATH here. `env -u JULIA_LOAD_PATH` would drop the value
    # Distributed exported on the SSH command line.
    push!(argv, "JULIA_LOAD_PATH=$(_LAUNCH_LOAD_PATH)")
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

function _rmprocs_added_since(before::AbstractSet{<:Integer})
    leftover = Int[w for w in workers() if w ∉ before]
    try
        isempty(leftover) || rmprocs(leftover; waitfor = 30)
    catch
    end
    return nothing
end

function _add_local_drive_workers!(n::Int, project::AbstractString, julia_bin::AbstractString)
    n < 1 && return nothing
    flags = Cmd(worker_exeflag_strings(project; local_cpu = true, job_id = resolved_kit_job_id()))
    before = Set(workers())
    try
        for i in 1:n
            env = worker_env_pairs(project; rank = take_worker_rank())
            addprocs(
                1;
                exename = julia_bin,
                exeflags = flags,
                env = env,
                topology = :master_worker,
            )
            i == 1 || continue
            added = sort!(Int[w for w in workers() if w ∉ before])
            isempty(added) || _precompile_worker_project!(first(added))
        end
    catch
        _rmprocs_added_since(before)
        rethrow()
    end
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
    exename = ssh_worker_exename(julia_bin)
    before = Set(workers())
    try
        for i in 1:n
            env = worker_env_pairs(project; ssh = true, rank = take_worker_rank())
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
            i == 1 || continue
            added = sort!(Int[w for w in workers() if w ∉ before])
            isempty(added) && return nothing
            _precompile_worker_project!(first(added))
        end
    catch
        _rmprocs_added_since(before)
        rethrow()
    end
    return nothing
end

function go_remote_julia_prefix(
        julia_bin::AbstractString;
        blas::Union{Nothing, AbstractString} = nothing,
    )::String
    jb = _remote_shell_path_word(julia_bin)
    flags = worker_exeflag_strings("."; local_cpu = false)
    flag_s = sprint() do io
        for f in flags
            print(io, ' ', posix_quote(f))
        end
    end
    blas_s = blas === nothing ? "" :
        " OPENBLAS_NUM_THREADS=$(posix_quote(String(blas))) OMP_NUM_THREADS=$(posix_quote(String(blas)))"
    return "$(_env_unset_prefix())$blas_s JULIA_LOAD_PATH=$(posix_quote(_LAUNCH_LOAD_PATH)) $(jb)$(flag_s)"
end
