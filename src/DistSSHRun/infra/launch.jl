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

function _worker_load_path_entries()::Vector{String}
    parts = String["@", "@stdlib"]
    d = pkgdir(@__MODULE__)
    if d !== nothing
        ds = String(d)
        !isempty(ds) && !(ds in parts) && push!(parts, ds)
    end
    return parts
end

function worker_load_path(; ssh::Bool = false)::String
    # Job packages load via `--project=` only; kit source is pinned explicitly,
    # not inherited from the parent's active project or sandbox LOAD_PATH.
    ssh # keyword kept for call-site documentation
    sep = Sys.iswindows() ? ";" : ":"
    return join(_worker_load_path_entries(), sep)
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

"""Provenance and mixer schema id for launch ranks and worker streams (frozen at `1` for 0.2.0)."""
const SEED_SCHEME = 1
const DOMAIN_JOB = 0x44535348_4a4f4201
const DOMAIN_WORKER = 0x44535348_574f524b
const DOMAIN_ITEM = 0x44535348_4954454d

const _JOB_SEED = Ref{Union{Nothing, UInt64}}(nothing)
const _PLANNED_RANK_QUEUE = Int[]
const _ASSIGNED_RANKS = Int[]
const _PID_TO_RANK = Dict{Int, Int}()
const _NEXT_PMAP_CALL = Ref(1)
const _ITEM_MAP = Dict{Tuple{Int, Int}, Int}()
const _ITEM_LOCK = ReentrantLock()

"""Splitmix-style mix for reproducible seeds (never `Base.hash`)."""
function seed_mix(domain::UInt64, a::UInt64, b::UInt64)::UInt64
    x = xor(domain, xor(a, b * 0x9E3779B97F4A7C15))
    x = xor(x, x >> 30) * 0xBF58476D1CE4E5B9
    x = xor(x, x >> 27) * 0x94D049BB133111EB
    return xor(x, x >> 31)
end

"""One seed for this run. `DISTSSH_JOB_SEED` wins when it is a `UInt64`."""
function job_seed()::UInt64
    existing = _JOB_SEED[]
    existing !== nothing && return existing
    parsed = tryparse(UInt64, strip(get(ENV, "DISTSSH_JOB_SEED", "")))
    seed = parsed === nothing ? rand(UInt64) : parsed
    _JOB_SEED[] = seed
    return seed
end

"""Job-wide stream seed (`SEED_SCHEME` 1)."""
function job_domain_seed(job::Integer)::UInt64
    return seed_mix(DOMAIN_JOB, UInt64(job), UInt64(SEED_SCHEME))
end

"""Stable worker seed from the job seed and a plan rank. Does not read `myid()`."""
function worker_seed(job::Integer, rank::Integer)::UInt64
    rank >= 1 || throw(ArgumentError("worker rank must be ≥ 1, got $rank"))
    return seed_mix(DOMAIN_WORKER, UInt64(job), UInt64(rank))
end

"""Per `worker_pmap` item stream seed (`SEED_SCHEME` 1)."""
function job_item_seed(job::Integer, call::Integer, item::Integer)::UInt64
    tag = xor(UInt64(call), UInt64(item) * 0x9E3779B97F4A7C15)
    return seed_mix(DOMAIN_ITEM, UInt64(job), tag)
end

"""Plan-fixed ranks before launch (local head slots, then each host in order)."""
function build_launch_rank_plan(
        head_workers::Integer,
        hosts::AbstractVector{<:Tuple{<:AbstractString, Union{Integer, Nothing}}},
        default_workers::Integer,
    )::Vector{Int}
    out = Int[]
    hw = Int(head_workers)
    hw > 0 && append!(out, 1:hw)
    def = Int(default_workers)
    for (_, spec) in hosts
        n = spec === nothing ? def : Int(spec)
        n > 0 && append!(out, (length(out) + 1):(length(out) + n))
    end
    return out
end

function reset_launch_rank_plan!(ranks::AbstractVector{<:Integer})
    _JOB_SEED[] = nothing
    empty!(_PLANNED_RANK_QUEUE)
    append!(_PLANNED_RANK_QUEUE, Int.(collect(ranks)))
    empty!(_ASSIGNED_RANKS)
    empty!(_PID_TO_RANK)
    lock(_ITEM_LOCK) do
        _NEXT_PMAP_CALL[] = 1
        empty!(_ITEM_MAP)
    end
    return nothing
end

function reset_worker_seeds!()
    return reset_launch_rank_plan!(Int[])
end

function take_worker_rank()::Int
    isempty(_PLANNED_RANK_QUEUE) && throw(
        ArgumentError("launch rank plan exhausted (internal); call reset_launch_rank_plan! first"),
    )
    rank = popfirst!(_PLANNED_RANK_QUEUE)
    push!(_ASSIGNED_RANKS, rank)
    return rank
end

function register_launch_rank!(pid::Integer, rank::Integer)
    _PID_TO_RANK[Int(pid)] = Int(rank)
    return nothing
end

"""
Launch plan rank for a worker `pid`, or `nothing` when unknown.

Ranks are fixed before `addprocs` via the launch plan. Provenance lists each
assigned rank under `provenance.seeds.workers`; the 0.2.0 cluster manager reads
the same map.
"""
function launch_rank(pid::Integer)::Union{Nothing, Int}
    return get(_PID_TO_RANK, Int(pid), nothing)
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

"""`DISTSSH_BLAS_THREADS` when the operator set it, else `nothing`."""
function _explicit_blas_threads()::Union{Nothing, String}
    raw = strip(get(ENV, "DISTSSH_BLAS_THREADS", ""))
    isempty(raw) && return nothing
    return raw
end

"""Positive `DISTSSH_BLAS_THREADS` when set; else `nothing`."""
function _requested_worker_blas_count()::Union{Nothing, Int}
    raw = _explicit_blas_threads()
    raw === nothing && return nothing
    n = tryparse(Int, raw)
    (n === nothing || n < 1) &&
        throw(ArgumentError("DISTSSH_BLAS_THREADS must be a positive integer, got $(repr(raw))"))
    return n
end

"""`addprocs` keyword args for BLAS threading on workers."""
function worker_addprocs_blas_kwargs()::NamedTuple
    _requested_worker_blas_count() === nothing && return NamedTuple()
    return (enable_threaded_blas = true,)
end

const _WORKER_PKG_UUID = Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
const _WORKER_PKG_PRECOMPILE_EXPR = :(
    let
        pkg = Base.PkgId($(_WORKER_PKG_UUID), "Pkg")
        mod = Base.invokelatest(Base.require, pkg)
        Base.invokelatest(() -> mod.precompile(; io = devnull))
        nothing
    end
)

function _worker_blas_apply_expr(n::Int)
    return :((using LinearAlgebra; BLAS.set_num_threads($(n)); BLAS.get_num_threads()))
end

function _apply_worker_blas_threads!(wids::AbstractVector{<:Integer})
    want = _requested_worker_blas_count()
    want === nothing && return nothing
    ex_set = _worker_blas_apply_expr(want)
    for wid in wids
        w = Int(wid)
        actual = remotecall_fetch(Core.eval, w, Main, ex_set)
        actual == want && continue
        host = remotecall_fetch(Core.eval, w, Main, :(gethostname()))
        rank_s = remotecall_fetch(
            Core.eval,
            w,
            Main,
            :(get(ENV, "DISTSSH_WORKER_RANK", string(myid()))),
        )
        error(
            "BLAS thread count on $(host) (rank $(rank_s)): requested $(want), got $(actual)",
        )
    end
    return nothing
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
        push!(pairs, "DISTSSH_JOB_SEED" => string(seed))
        push!(pairs, "DISTSSH_WORKER_RANK" => string(r))
        push!(pairs, "DISTSSH_WORKER_SEED" => string(worker_seed(seed, r)))
    end
    id = resolved_kit_job_id()
    id === nothing || push!(pairs, "DISTSSH_JOB_ID" => id)
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
    want = worker_load_path()
    if lp isa AbstractString && !isempty(strip(lp)) && strip(lp) != want
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
    push!(argv, "JULIA_LOAD_PATH=$(worker_load_path(; ssh = true))")
    push!(argv, String(julia_path))
    return Cmd(argv)
end

function ssh_addprocs_machine_bind(host::AbstractString, bind::AbstractString)::String
    return string(ssh_addprocs_machine(host), " ", String(strip(bind)))
end

function ssh_addprocs_bind_localhost(host::AbstractString)::String
    return ssh_addprocs_machine_bind(host, "127.0.0.1")
end

function ssh_tunnel_enabled()::Bool
    return get(ENV, "DISTSSH_SSH_TUNNEL", "1") != "0"
end

"""
Restore the caller's task-local default RNG after `f` returns (even when `f` throws).

Uses only `Random.default_rng`, `copy`, and `copy!`. Worker launch may call
`Distributed.cluster_cookie` and `addprocs`, which can advance the controller
task's default RNG on some Julia versions; on others they may not. Restoring the
saved RNG makes the outcome the same as if launch had not consumed that stream.
`addprocs` can still spawn internal tasks that advance split RNG state; Julia
does not expose a public API to rewind child-task streams, so only this task's
default RNG is restored. Call `Random.seed!` again once the cluster is up when
you need bit-identical streams to a script that never started workers.

Call this around `ensure_run_cluster_cookie!` and every `addprocs` on the
controller, in the task that calls `addprocs`.
"""
function preserve_task_local_default_rng(f::Function)
    rng = default_rng()
    saved = copy(rng)
    try
        return f()
    finally
        copy!(rng, saved)
    end
end

# Distributed has no public "multiprocessing initialized" API. `inited` matches
# whether `cluster_cookie` / `addprocs` have run on this process. Drop this probe
# when stdlib exposes a stable replacement and update `verify_distributed_init_probe!`.
function _distributed_inited_value()::Bool
    flag = getfield(Distributed, :inited)
    flag isa Ref{Bool} && return flag[]
    flag isa Base.Threads.Atomic{Bool} && return flag[]
    error(
        "Distributed init probe: :inited has type $(typeof(flag)); " *
            "update _distributed_inited_value",
    )
end

function _distributed_multi_initialized()::Bool
    nprocs() > 1 && return true
    return _distributed_inited_value()
end

"""
Loud check that the Distributed `inited` probe still matches stdlib layout.
Called from cluster-cookie tests so CI fails if the internal layout changes.
"""
function verify_distributed_init_probe!()
    isdefined(Distributed, :inited) ||
        error("Distributed init probe: missing binding :inited; update _distributed_inited_value")
    _distributed_inited_value()
    return nothing
end

"""
Set a per-run cluster cookie before the first worker. Never log the value.

Runs inside [`preserve_task_local_default_rng`](@ref) on the controller. Does
not replace a cookie you already chose: if Distributed is already initialized
(for example after `Distributed.cluster_cookie` or `addprocs` in your script),
the existing cookie is kept. The new cookie uses `RandomDevice`, not the
default RNG.
"""
function ensure_run_cluster_cookie!()::Nothing
    nprocs() > 1 && return nothing
    _distributed_multi_initialized() && return nothing
    Distributed.cluster_cookie(randstring(RandomDevice(), 16))
    return nothing
end

function _worker_precompile_rank(wid::Int)::String
    return try
        string(
            remotecall_fetch(
                Core.eval,
                wid,
                Main,
                :(get(ENV, "DISTSSH_WORKER_RANK", string(myid()))),
            ),
        )
    catch
        string(wid)
    end
end

function _worker_precompile_host(wid::Int)::String
    return try
        string(remotecall_fetch(Core.eval, wid, Main, :(gethostname())))
    catch
        return "worker $wid"
    end
end

function _warn_worker_project_precompile!(
        wid::Int,
        project::AbstractString,
        headline::AbstractString;
        err::Union{Nothing, Exception} = nothing,
    )::Nothing
    host = _worker_precompile_host(wid)
    rank = _worker_precompile_rank(wid)
    proj = String(project)
    msg = "Warning: worker project precompile on $(host) (rank $(rank)), project=$(proj): $(headline)"
    err === nothing || (msg *= "\n$(sprint(showerror, err))")
    print_warn(msg * "\n"; io = stderr)
    return nothing
end

function _precompile_worker_project!(wid::Int, project::AbstractString)::Bool
    p = String(project)
    if !isdir(p) || !Base.Filesystem.iswritable(p)
        _warn_worker_project_precompile!(
            wid,
            p,
            "project directory is not writable; precompile not attempted",
        )
        return true
    end
    try
        remotecall_wait(Core.eval, wid, Main, _WORKER_PKG_PRECOMPILE_EXPR)
        return true
    catch e
        _warn_worker_project_precompile!(wid, p, "precompile failed"; err = e)
        return false
    end
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

function _add_local_drive_workers!(
        n::Int,
        project::AbstractString,
        julia_bin::AbstractString;
        verify_project::Bool = true,
    )
    n < 1 && return nothing
    isempty(_PLANNED_RANK_QUEUE) && reset_launch_rank_plan!(collect(1:n))
    flags = Cmd(worker_exeflag_strings(project; local_cpu = true, job_id = resolved_kit_job_id()))
    before = Set(workers())
    try
        for i in 1:n
            rank = take_worker_rank()
            env = worker_env_pairs(project; ssh = false, rank = rank)
            joined = addprocs(
                1;
                exename = julia_bin,
                exeflags = flags,
                env = env,
                topology = topology_for_launch(),
                worker_addprocs_blas_kwargs()...,
            )
            just = Int[Int(w) for w in joined]
            for w in just
                register_launch_rank!(w, rank)
            end
            _mark_workers_launched!(just, project)
            _apply_worker_blas_threads!(just)
            i == 1 || continue
            added = sort!(just)
            verify_project ||
                continue
            isempty(added) || _precompile_worker_project!(first(added), project)
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
        placement_ssh_endpoint::AbstractString,
    )
    n < 1 && return nothing
    flags = Cmd(worker_exeflag_strings(project; local_cpu = false, job_id = resolved_kit_job_id()))
    exename = ssh_worker_exename(julia_bin)
    before = Set(workers())
    try
        for i in 1:n
            rank = take_worker_rank()
            env = worker_env_pairs(project; ssh = true, rank = rank)
            joined = addprocs(
                [(machine, 1)];
                exename = exename,
                sshflags = sshflags,
                dir = project,
                tunnel = ssh_tunnel_enabled(),
                cmdline_cookie = false,
                exeflags = flags,
                env = env,
                topology = topology_for_launch(),
                worker_addprocs_blas_kwargs()...,
            )
            just = Int[Int(w) for w in joined]
            for w in just
                register_launch_rank!(w, rank)
            end
            _register_worker_placement_ssh_endpoints!(just, placement_ssh_endpoint)
            _mark_workers_launched!(just, project)
            _apply_worker_blas_threads!(just)
            i == 1 || continue
            added = sort!(just)
            isempty(added) && return nothing
            _precompile_worker_project!(first(added), project)
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
    return "$(_env_unset_prefix())$blas_s JULIA_LOAD_PATH=$(posix_quote(worker_load_path(; ssh = true))) $(jb)$(flag_s)"
end
