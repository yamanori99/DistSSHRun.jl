# Versioned detached/Queue job settings (`job.toml`); argv is bootstrap only.

const DETACHED_JOB_BLOB_FILENAME::String = "job.toml"
const DETACHED_JOB_BLOB_ENV::String = "DISTSSH_INTERNAL_JOB_BLOB"

const _DETACHED_PLACEMENT_ENV_KEYS = (
    "DISTSSH_HOSTS",
    "DISTSSH_HOSTS_FILE",
)

const _DETACHED_JOB_SHARED_ENV_KEYS = (
    "DISTSSH_QUIET",
    "DISTSSH_PROGRESS",
    "DISTSSH_VERBOSE",
    "DISTSSH_YES",
    "DISTSSH_JOBS",
    "DISTSSH_HEAD_WORKERS",
    "DISTSSH_SKIP_GLOBAL_WORKER_PKILL",
    "JULIA_DISTRIBUTED_EXE",
    "DISTSSH_REQUIRE_ALL_HOSTS",
    "DISTSSH_BEST_EFFORT",
    "DISTSSH_INTERNAL_JOB_BLOB",
)

const _JOB_BLOB_BOOTSTRAP_YES = ("-y", "--yes")

function _detached_job_default_env_keys()::Vector{String}
    keys = Set{String}()
    for k in _DETACHED_PLACEMENT_ENV_KEYS
        push!(keys, k)
    end
    for k in _DETACHED_JOB_SHARED_ENV_KEYS
        push!(keys, k)
    end
    for row in run_option_table()
        row.env === nothing && continue
        push!(keys, String(row.env))
    end
    return sort!(collect(keys))
end

"""Usage error when bootstrap argv is not only `-y` / `--yes` plus `--job-blob PATH`."""
function assert_detached_job_blob_bootstrap_argv!(args::AbstractVector{<:AbstractString})
    args_vec = String[String(x) for x in args]
    for i in eachindex(args_vec)
        args_vec[i] == "--job-blob" || continue
        i >= length(args_vec) &&
            throw(ArgumentError("--job-blob requires a path"))
        trailing = args_vec[(i + 2):end]
        isempty(trailing) && break
        extra = join(trailing, " ")
        throw(
            ArgumentError(
                "unexpected argv after --job-blob PATH: $(extra); "
                    * "detached bootstrap is -y/--yes and --job-blob PATH only",
            ),
        )
    end
    _, rest = peel_job_blob_bootstrap(copy(args_vec))
    for arg in rest
        arg in _JOB_BLOB_BOOTSTRAP_YES && continue
        throw(
            ArgumentError(
                "unexpected argv with --job-blob: $(arg); "
                    * "detached bootstrap is -y/--yes and --job-blob PATH only",
            ),
        )
    end
    return nothing
end

"""Absolute path to the job blob under `run_dir`."""
function detached_job_blob_path(run_dir::AbstractString)::String
    return joinpath(canonical_local_path(String(run_dir)), DETACHED_JOB_BLOB_FILENAME)
end

function _blob_string_vec(v)::Vector{String}
    v isa AbstractVector || throw(ArgumentError("job blob: expected string array"))
    return String[String(x) for x in v]
end

const _JOB_BLOB_REQUIRE_ALL_HOSTS_REMOVED = """
job blob: require_all_hosts was removed; use best_effort instead (invert the value).
  require_all_hosts = true  →  best_effort = false  (default, fail-closed join/collect)
  require_all_hosts = false →  best_effort = true
Rewrite job.toml; silent conversion is not supported."""

const _JOB_BLOB_COLLECT_BEST_EFFORT_REMOVED = """
job blob: collect_best_effort was removed; use best_effort instead (same meaning).
Rewrite job.toml; silent conversion is not supported."""

const _JOB_BLOB_RUN_ID_REMOVED = """
job blob: run_id was removed; use ship_id instead.
Rewrite job.toml; silent conversion is not supported."""

function _reject_removed_job_blob_join_keys!(raw::AbstractDict)
    haskey(raw, "require_all_hosts") && throw(ArgumentError(_JOB_BLOB_REQUIRE_ALL_HOSTS_REMOVED))
    haskey(raw, "collect_best_effort") && throw(ArgumentError(_JOB_BLOB_COLLECT_BEST_EFFORT_REMOVED))
    haskey(raw, "run_id") && throw(ArgumentError(_JOB_BLOB_RUN_ID_REMOVED))
    return nothing
end

function _blob_best_effort(raw::AbstractDict)::Bool
    if haskey(raw, "best_effort")
        return _blob_bool(raw["best_effort"], "best_effort")
    end
    return false
end

function _blob_bool(raw, name::AbstractString)::Bool
    raw isa Bool && return raw
    raw isa Integer && return raw != 0
    raw isa AbstractString && return lowercase(strip(String(raw))) in ("1", "true", "yes", "on")
    throw(ArgumentError("job blob: $(name) must be a boolean"))
end

function _blob_optional_string(raw)::Union{Nothing, String}
    raw === nothing && return nothing
    s = strip(String(raw))
    isempty(s) && return nothing
    return s
end

function _blob_optional_float(raw, name::AbstractString)::Union{Nothing, Float64}
    raw === nothing && return nothing
    if raw isa Real
        v = Float64(raw)
        v > 0 || throw(ArgumentError("job blob: $(name) must be positive"))
        return v
    end
    s = strip(String(raw))
    isempty(s) && return nothing
    parsed = tryparse(Float64, s)
    parsed === nothing && throw(ArgumentError("job blob: $(name) must be a number"))
    parsed > 0 || throw(ArgumentError("job blob: $(name) must be positive"))
    return parsed
end

const _DETACHED_BLOB_HEARTBEAT_DEADLINE = "distributed_heartbeat_deadline_sec"
const _DETACHED_BLOB_HEARTBEAT_INTERVAL = "distributed_heartbeat_interval_sec"
const _DETACHED_HEARTBEAT_DEADLINE_ENV = "DISTSSH_HEARTBEAT_DEADLINE_SEC"
const _DETACHED_HEARTBEAT_INTERVAL_ENV = "DISTSSH_HEARTBEAT_INTERVAL_SEC"

"""Job-default option fields to store in the blob from the parent `ProcessEnv` at write time."""
function detached_job_blob_fields_from_env(env::ProcessEnv = snapshot_process_env())
    fields = Dict{Symbol, Any}()
    for row in run_option_table()
        row.env === nothing && continue
        if row.default isa AbstractString
            raw = strip(get(env, String(row.env), ""))
            isempty(raw) && continue
            String(row.default) != raw && (fields[row.key] = raw)
            continue
        end
        flag = _bool_env(String(row.env); env = env)
        flag === true && (fields[row.key] = true)
    end
    dl = _blob_optional_float(get(env, _DETACHED_HEARTBEAT_DEADLINE_ENV, nothing), "heartbeat_deadline")
    dl !== nothing && (fields[Symbol(_DETACHED_BLOB_HEARTBEAT_DEADLINE)] = dl)
    iv = _blob_optional_float(get(env, _DETACHED_HEARTBEAT_INTERVAL_ENV, nothing), "heartbeat_interval")
    iv !== nothing && (fields[Symbol(_DETACHED_BLOB_HEARTBEAT_INTERVAL)] = iv)
    return fields
end

"""`ProcessEnv` for a detached child after scrub: heartbeat timing from the blob only."""
function detached_job_blob_child_process_env(
        base::ProcessEnv,
        blob,
    )
    data = copy(base.data)
    if blob.distributed_heartbeat_deadline_sec !== nothing
        data[_DETACHED_HEARTBEAT_DEADLINE_ENV] = string(blob.distributed_heartbeat_deadline_sec)
    end
    if blob.distributed_heartbeat_interval_sec !== nothing
        data[_DETACHED_HEARTBEAT_INTERVAL_ENV] = string(blob.distributed_heartbeat_interval_sec)
    end
    if blob.topology !== nothing
        data["DISTSSH_TOPOLOGY"] = blob.topology
    end
    return ProcessEnv(data)
end

function _validate_detached_job_blob_dict(raw::AbstractDict)
    writer = get(raw, "writer", nothing)
    kind = DistSSHBase.record_writer_minor_match(
        writer,
        _RUN_RECORD_PACKAGE,
        dist_ssh_kit_version(),
    )
    kind == :ok || throw(
        ArgumentError(
            DistSSHBase.record_writer_mismatch_message(
                kind,
                writer,
                _RUN_RECORD_PACKAGE,
                dist_ssh_kit_version();
                fix = "Rewrite job.toml or rerun the command that wrote it.",
            ),
        ),
    )
    kind = get(raw, "kind", nothing)
    kind isa AbstractString || throw(ArgumentError("job blob: missing kind"))
    sym = Symbol(String(kind))
    sym in (:go, :drive) || throw(
        ArgumentError("job blob: kind must be go or drive, got $(repr(kind))"),
    )
    script = get(raw, "script", nothing)
    script isa AbstractString || throw(ArgumentError("job blob: missing script"))
    tokens = get(raw, "tokens", String[])
    _blob_string_vec(tokens)
    args = get(raw, "script_args", String[])
    _blob_string_vec(args)
    get(raw, "project", nothing) isa AbstractString ||
        throw(ArgumentError("job blob: missing project"))
    _reject_removed_job_blob_join_keys!(raw)
    return nothing
end

"""
    read_detached_job_blob(path) -> NamedTuple

Load and validate a detached job blob. Writer `major.minor` must match this package.
"""
function read_detached_job_blob(path::AbstractString)
    p = canonical_local_path(String(path))
    isfile(p) || throw(ArgumentError("job blob not found: $(p)"))
    raw = TOML.parsefile(p)
    raw isa AbstractDict || throw(ArgumentError("job blob: invalid TOML"))
    _validate_detached_job_blob_dict(raw)
    kind = Symbol(String(get(raw, "kind", nothing)))
    script = get(raw, "script", nothing)
    project = get(raw, "project", nothing)
    return (
        writer = String(get(raw, "writer", "")),
        kind = kind,
        script = String(script),
        tokens = _blob_string_vec(get(raw, "tokens", String[])),
        script_args = _blob_string_vec(get(raw, "script_args", String[])),
        project = String(project),
        remote = _blob_optional_string(get(raw, "remote", nothing)),
        output_dir = _blob_optional_string(get(raw, "output_dir", nothing)),
        log_dir = _blob_optional_string(get(raw, "log_dir", nothing)),
        julia = _blob_optional_string(get(raw, "julia", nothing)),
        ship_id = let rid = _blob_optional_string(get(raw, "ship_id", nothing))
            rid === nothing ? nothing : validate_ship_id(rid)
        end,
        quiet = _blob_bool(get(raw, "quiet", false), "quiet"),
        verbosity = _blob_optional_string(get(raw, "verbosity", nothing)),
        best_effort = _blob_best_effort(raw),
        skip_hash_check = _blob_bool(get(raw, "skip_hash_check", true), "skip_hash_check"),
        enable_log = _blob_bool(get(raw, "enable_log", true), "enable_log"),
        package = _blob_optional_string(get(raw, "package", nothing)),
        workers = let w = get(raw, "workers", nothing)
            w === nothing ? nothing : Int(w)
        end,
        repeat = let r = get(raw, "repeat", nothing)
            r === nothing ? nothing : Int(r)
        end,
        worker_include = _blob_bool(get(raw, "worker_include", false), "worker_include"),
        spi_check = _blob_bool(get(raw, "spi_check", false), "spi_check"),
        unsafe_skip_env_digests = _blob_bool(
            get(raw, "unsafe_skip_env_digests", false),
            "unsafe_skip_env_digests",
        ),
        job_id = _blob_optional_string(get(raw, "job_id", nothing)),
        head_workers = let w = get(raw, "head_workers", nothing)
            w === nothing ? nothing : Int(w)
        end,
        head_slots = let s = get(raw, "head_slots", nothing)
            s === nothing ? nothing : Int(s)
        end,
        allow_external_symlinks = _blob_bool(
            get(raw, "allow_external_symlinks", false),
            "allow_external_symlinks",
        ),
        unsafe_master_silence_exit = _blob_bool(
            get(raw, "unsafe_master_silence_exit", false),
            "unsafe_master_silence_exit",
        ),
        unsafe_expose_port = _blob_bool(get(raw, "unsafe_expose_port", false), "unsafe_expose_port"),
        unsafe_all_to_all = _blob_bool(get(raw, "unsafe_all_to_all", false), "unsafe_all_to_all"),
        topology = _blob_optional_string(get(raw, "topology", nothing)),
        distributed_heartbeat_deadline_sec = _blob_optional_float(
            get(raw, _DETACHED_BLOB_HEARTBEAT_DEADLINE, nothing),
            "distributed_heartbeat_deadline_sec",
        ),
        distributed_heartbeat_interval_sec = _blob_optional_float(
            get(raw, _DETACHED_BLOB_HEARTBEAT_INTERVAL, nothing),
            "distributed_heartbeat_interval_sec",
        ),
    )
end

"""Remove job-default keys from `ENV` after the blob is loaded (placement and option env)."""
function scrub_detached_placement_env!()
    for k in _detached_job_default_env_keys()
        delete!(ENV, k)
    end
    delete!(ENV, _DETACHED_HEARTBEAT_DEADLINE_ENV)
    delete!(ENV, _DETACHED_HEARTBEAT_INTERVAL_ENV)
    return nothing
end

function _write_job_blob_pairs(io::IO, pairs::Vector{Pair{String, Any}})
    for (k, v) in pairs
        if v isa Bool
            println(io, "$k = ", v ? "true" : "false")
        elseif v isa AbstractFloat
            println(io, "$k = ", v)
        elseif v isa AbstractString
            println(io, "$k = ", repr(v))
        elseif v isa Integer
            println(io, "$k = ", v)
        elseif v isa AbstractVector
            print(io, "$k = [")
            for (i, x) in enumerate(v)
                i > 1 && print(io, ", ")
                print(io, repr(String(x)))
            end
            println(io, "]")
        end
    end
    return nothing
end

"""
    write_detached_job_blob!(
        run_dir,
        kind,
        script,
        tokens,
        script_args,
        project;
        kwargs...
    ) -> String

Write `job.toml` under `run_dir`. Returns the blob path.
"""
function write_detached_job_blob!(
        run_dir::AbstractString,
        kind::Symbol,
        script::AbstractString,
        tokens::AbstractVector{<:AbstractString},
        script_args::AbstractVector{<:AbstractString},
        project::AbstractString;
        remote = nothing,
        output_dir = nothing,
        log_dir = nothing,
        julia = nothing,
        ship_id = nothing,
        quiet::Bool = false,
        verbosity = nothing,
        best_effort::Bool = false,
        skip_hash_check::Bool = true,
        enable_log::Bool = true,
        package = nothing,
        workers = nothing,
        repeat = nothing,
        worker_include::Bool = false,
        unsafe_skip_env_digests::Bool = false,
        job_id = nothing,
        allow_external_symlinks::Bool = false,
        head_workers = nothing,
        head_slots = nothing,
        unsafe_master_silence_exit::Bool = false,
        unsafe_expose_port::Bool = false,
        unsafe_all_to_all::Bool = false,
        topology = nothing,
        distributed_heartbeat_deadline_sec = nothing,
        distributed_heartbeat_interval_sec = nothing,
    )::String
    _require_execute_kind!(kind)
    path = detached_job_blob_path(run_dir)
    mkpath(dirname(path))
    pairs = Pair{String, Any}[
        "writer" => run_record_writer(),
        "kind" => String(kind),
        "script" => String(script),
        "tokens" => collect(String, tokens),
        "script_args" => collect(String, script_args),
        "project" => canonical_local_path(String(project)),
    ]
    for (k, v) in (
            (:remote, remote),
            (:output_dir, output_dir),
            (:log_dir, log_dir),
            (:julia, julia),
            (:ship_id, ship_id),
            (:package, package),
            (:job_id, job_id),
        )
        val = v === nothing ? nothing : strip(String(v))
        val !== nothing && !isempty(val) && push!(pairs, String(k) => val)
    end
    verbosity !== nothing && push!(pairs, "verbosity" => String(verbosity))
    workers !== nothing && push!(pairs, "workers" => Int(workers))
    repeat !== nothing && push!(pairs, "repeat" => Int(repeat))
    head_workers !== nothing && push!(pairs, "head_workers" => Int(head_workers))
    head_slots !== nothing && push!(pairs, "head_slots" => Int(head_slots))
    for (k, v) in (
            (:quiet, quiet),
            (:best_effort, best_effort),
            (:skip_hash_check, skip_hash_check),
            (:enable_log, enable_log),
            (:worker_include, worker_include),
            (:unsafe_skip_env_digests, unsafe_skip_env_digests),
            (:allow_external_symlinks, allow_external_symlinks),
            (:unsafe_master_silence_exit, unsafe_master_silence_exit),
            (:unsafe_expose_port, unsafe_expose_port),
            (:unsafe_all_to_all, unsafe_all_to_all),
        )
        push!(pairs, String(k) => v)
    end
    topology_s = topology === nothing ? nothing : strip(String(topology))
    topology_s !== nothing && !isempty(topology_s) && push!(pairs, "topology" => topology_s)
    distributed_heartbeat_deadline_sec !== nothing &&
        push!(pairs, _DETACHED_BLOB_HEARTBEAT_DEADLINE => Float64(distributed_heartbeat_deadline_sec))
    distributed_heartbeat_interval_sec !== nothing &&
        push!(pairs, _DETACHED_BLOB_HEARTBEAT_INTERVAL => Float64(distributed_heartbeat_interval_sec))
    open(path, "w") do io
        _write_job_blob_pairs(io, pairs)
    end
    return path
end

"""Expand a detached job blob into keywords for [`execute!`](@ref) or bang APIs."""
function execute_kwargs_from_job_blob(blob)
    kw = Dict{Symbol, Any}(
        :output_dir => blob.output_dir,
        :args => blob.script_args,
        :project => blob.project,
        :julia => blob.julia,
        :quiet => blob.quiet,
        :remote => blob.remote,
        :best_effort => blob.best_effort,
        :skip_hash_check => blob.skip_hash_check,
        :unsafe_skip_env_digests => blob.unsafe_skip_env_digests,
    )
    blob.verbosity !== nothing && (kw[:verbosity] = Symbol(blob.verbosity))
    blob.ship_id !== nothing && (kw[:ship_id] = blob.ship_id)
    blob.log_dir !== nothing && (kw[:log_dir] = blob.log_dir)
    blob.enable_log == false && (kw[:enable_log] = false)
    blob.package !== nothing && (kw[:package] = blob.package)
    blob.workers !== nothing && (kw[:workers] = blob.workers)
    blob.repeat !== nothing && (kw[:repeat] = blob.repeat)
    blob.worker_include && (kw[:worker_include] = true)
    blob.job_id !== nothing && (kw[:job_id] = blob.job_id)
    blob.head_workers !== nothing && (kw[:head_workers] = blob.head_workers)
    blob.head_slots !== nothing && (kw[:head_slots] = blob.head_slots)
    blob.allow_external_symlinks && (kw[:allow_external_symlinks] = true)
    return kw
end

"""Split `--job-blob PATH` from bootstrap argv; returns `(path, rest)`."""
function peel_job_blob_bootstrap(args::Vector{String})::Tuple{Union{Nothing, String}, Vector{String}}
    out = String[]
    blob = nothing
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--job-blob" && i < length(args)
            blob = canonical_local_path(String(args[i + 1]))
            i += 2
            continue
        end
        push!(out, arg)
        i += 1
    end
    return blob, out
end

function _blob_machine_hosts(tokens::AbstractVector{<:AbstractString})
    hosts = Tuple{String, Union{Int, Nothing}}[]
    for tok in tokens
        p = parse_placement_token(String(tok))
        p.role === :parent && throw(
            ArgumentError(
                "job blob: legacy parent token $(repr(tok)); use head_workers in the blob",
            ),
        )
        p.n === nothing &&
            throw(ArgumentError("job blob token needs a count: $(repr(tok))"))
        push!(hosts, (p.name, p.n))
    end
    return hosts
end

"""`parse_drive_args`-shaped NamedTuple from a detached job blob."""
function drive_parsed_from_detached_job_blob(
        blob;
        hint_surface::Symbol = :cli,
        process_env::ProcessEnv = detached_job_blob_child_process_env(
            snapshot_process_env(),
            blob,
        ),
    )
    head_workers = something(blob.head_workers, 0)
    hosts = _blob_machine_hosts(blob.tokens)
    cfg_quiet = blob.quiet
    verbosity = blob.verbosity === nothing ? nothing : Symbol(blob.verbosity)
    cli_session = CliSharedFlags(
        quiet = cfg_quiet,
        verbosity = verbosity,
        yes = true,
        show_version = false,
        hosts_file = nothing,
        hint_surface = hint_surface,
        process_env = process_env,
    )
    return (
        head_workers = head_workers,
        default_workers = nothing,
        julia = blob.julia,
        skip_hash_check = blob.skip_hash_check,
        enable_log = blob.enable_log,
        log_dir = blob.log_dir,
        output_dir = blob.output_dir,
        explicit_package = blob.package,
        hosts = hosts,
        script_path = blob.script,
        script_args = blob.script_args,
        collect_root = nothing,
        collect_hosts = nothing,
        collect_overwrite = nothing,
        worker_include = blob.worker_include,
        best_effort = blob.best_effort,
        help = false,
        show_version = false,
        cli_session = cli_session,
        hint_surface = hint_surface,
        unsafe_skip_env_digests = blob.unsafe_skip_env_digests,
        unsafe_expose_port = blob.unsafe_expose_port,
        unsafe_all_to_all = blob.unsafe_all_to_all,
        print_config = false,
        dry_run = false,
        ship_id = blob.ship_id,
        deploy_root = blob.remote,
        isolated = false,
        unsafe_master_silence_exit = blob.unsafe_master_silence_exit,
        job_blob = true,
    )
end

"""`parse_go_args`-shaped NamedTuple from a detached job blob."""
function go_parsed_from_detached_job_blob(
        blob;
        process_env::ProcessEnv = detached_job_blob_child_process_env(snapshot_process_env(), blob),
    )
    blob.kind === :go || throw(ArgumentError("job blob kind is $(blob.kind); expected go"))
    cli_session = CliSharedFlags(
        quiet = blob.quiet,
        verbosity = blob.verbosity === nothing ? nothing : Symbol(blob.verbosity),
        yes = true,
        show_version = false,
        hosts_file = nothing,
        hint_surface = :cli,
        head_slots = blob.head_slots,
        process_env = process_env,
    )
    run_opts = RunOptionCliState()
    run_opts.unsafe_skip_env_digests = blob.unsafe_skip_env_digests
    run_opts.unsafe_expose_port = blob.unsafe_expose_port
    run_opts.unsafe_all_to_all = blob.unsafe_all_to_all
    return _go_parsed(
        help = false,
        show_version = false,
        cli_session = cli_session,
        script_path = blob.script,
        script_args = blob.script_args,
        hosts = String[String(t) for t in blob.tokens],
        output_dir = blob.output_dir,
        julia = blob.julia,
        repeat = blob.repeat,
        run_opts = run_opts,
        ship_id = blob.ship_id,
        deploy_root = blob.remote,
    )
end

public DETACHED_JOB_BLOB_ENV, DETACHED_JOB_BLOB_FILENAME
public assert_detached_job_blob_bootstrap_argv!, detached_job_blob_child_process_env
public detached_job_blob_fields_from_env, detached_job_blob_path
public drive_parsed_from_detached_job_blob, execute_kwargs_from_job_blob
public go_parsed_from_detached_job_blob, peel_job_blob_bootstrap
public read_detached_job_blob, scrub_detached_placement_env!
public write_detached_job_blob!
