# Result types for the drive / sync API.
# `WorkerPlan` lives in `worker_plan.jl`.

"""Per-host outcome for sync and similar operations."""
struct HostResult
    host::String
    ok::Bool
    message::String
end

"""One warning printed by `setup!(session, :check)`.

`host` is `PARENT_HOST_NAME` for a local warning. `kind` names the check.
`message` is the same text `warn` printed.
"""
struct SetupWarning
    host::String
    kind::Symbol
    message::String
end

public SetupWarning

"""Outcome of `sync!` (rsync or git sync). `cancelled` is set when a confirm prompt is aborted.

`warnings` is empty except for `setup!(session, :check)`, which records each warning it printed.
[`result_content_tree_hash`](@ref) and [`result_remote_run_id`](@ref) read the
ship hash and remote `run_id` from a `:ship_tree` result, and return `nothing`
for any other mode. Fields are not API.
"""
struct SyncResult
    ok::Bool
    hosts::Vector{HostResult}
    cancelled::Bool
    warnings::Vector{SetupWarning}
    content_tree_hash::Union{Nothing, String}
    run_id::Union{Nothing, String}
    function SyncResult(
            ok::Bool,
            hosts::Vector{HostResult},
            cancelled::Bool,
            warnings::Vector{SetupWarning} = SetupWarning[],
            content_tree_hash::Union{Nothing, String} = nothing,
            run_id::Union{Nothing, String} = nothing,
        )
        return new(ok, hosts, cancelled, warnings, content_tree_hash, run_id)
    end
end

"""
Parsed drive/go worker tokens (explicit `:N` only).

Build with `DistSSHRun.parse_worker_tokens`; the keyword constructor here only
coerces types (same convenience shape as [`DriveResult`](@ref) /
[`PipelineResult`](@ref)), it does not re-validate cross-field consistency.

Field name matches [`WorkerPlan`](@ref): a host with an explicit `:N` is
`child_workers[host] = N`, same key as `WorkerPlan.child_workers`.
"""
struct ParsedWorkerTokens
    parent_workers::Int
    parent_autosize::Bool
    child_workers::Dict{String, Int}
    child_auto::Vector{String}
    child_hosts::Vector{String}
    tokens::Vector{String}
end

function ParsedWorkerTokens(;
        parent_workers::Integer = 0,
        parent_autosize::Bool = false,
        child_workers::AbstractDict{<:AbstractString, <:Integer} = Dict{String, Int}(),
        child_auto::AbstractVector{<:AbstractString} = String[],
        child_hosts::AbstractVector{<:AbstractString} = String[],
        tokens::AbstractVector{<:AbstractString} = String[],
    )
    return ParsedWorkerTokens(
        Int(parent_workers),
        parent_autosize,
        Dict{String, Int}(String(h) => Int(n) for (h, n) in child_workers),
        String[String(h) for h in child_auto],
        String[String(h) for h in child_hosts],
        String[String(t) for t in tokens],
    )
end

"""
    parse_worker_tokens(tokens) -> ParsedWorkerTokens

Classify CLI-style tokens. `hostinfo` / `pool` / `setup` may omit `:N` (host list).
go / drive / ride placement requires `:N` except `go --repeat` (omit = uncapped).
"""
function parse_worker_tokens(
        tokens::AbstractVector{<:AbstractString},
    )::ParsedWorkerTokens
    parent_workers = 0
    local_seen = false
    parent_autosize = false
    child_workers = Dict{String, Int}()
    child_auto = String[]
    child_hosts = String[]
    seen_remote = Set{String}()
    out_tokens = String[String(t) for t in tokens]

    for raw in out_tokens
        p = parse_placement_token(raw)
        if p.role === :parent
            local_seen && throw(
                ArgumentError(
                    "duplicate parent token; use one of $(PARENT_HOST_NAME):N",
                )
            )
            local_seen = true
            if p.n === nothing
                parent_autosize = true
            else
                parent_workers = Int(p.n)
            end
        else
            host = p.name
            n = p.n
            if !(host in seen_remote)
                push!(child_hosts, host)
                push!(seen_remote, host)
            end
            if n === nothing
                push!(child_auto, host)
            else
                child_workers[host] = Int(n)
            end
        end
    end
    return ParsedWorkerTokens(
        parent_workers,
        parent_autosize,
        child_workers,
        child_auto,
        child_hosts,
        out_tokens,
    )
end

"""True when every token has an explicit worker/slot count (`:N`)."""
function worker_tokens_fully_specified(parsed::ParsedWorkerTokens)::Bool
    return !parsed.parent_autosize && isempty(parsed.child_auto)
end

"""Throw unless every token has `:N` (go / drive / ride placement)."""
function require_counted_placement_tokens(
        tokens::AbstractVector{<:AbstractString};
        surface::Symbol = :api,
    )::Nothing
    isempty(tokens) && return nothing
    parsed = parse_worker_tokens(tokens)
    worker_tokens_fully_specified(parsed) && return nothing
    throw(ArgumentError(explain_bare_placement_tokens(tokens; surface = surface)))
end

"""SSH host names from tokens (parent tokens omitted)."""
function child_hosts_from_tokens(tokens::AbstractVector{<:AbstractString})::Vector{String}
    return parse_worker_tokens(tokens).child_hosts
end

"""Optional path string (`nothing` when unset or empty)."""
function _optional_path(path::Union{Nothing, AbstractString})::Union{Nothing, String}
    path === nothing && return nothing
    s = String(path)
    return isempty(s) ? nothing : s
end

"""
Per-host outcome of the `drive` result-collection step.

`ok` is `false` when SSH / `find` / rsync raises while collecting from `host`.
An empty file list after a successful probe is not an error. `error` is the
message string, or `nothing` on success. An `AbstractString` is stored as-is
so `kit.result` round-trips; other values use `sprint(showerror, error)`.
"""
struct HostRunResult
    host::String
    ok::Bool
    error::Union{Nothing, String}
end

function _host_run_error_text(error)::Union{Nothing, String}
    error === nothing && return nothing
    error isa AbstractString && return String(error)
    return sprint(showerror, error)
end

HostRunResult(host::AbstractString, ok::Bool, error = nothing) =
    HostRunResult(String(host), ok, _host_run_error_text(error))

const _KIT_STOP_OUTCOMES = (:within_grace, :sigterm, :sigkill, :no_sigint)

function _kit_stop_symbol(raw)::Union{Nothing, Symbol}
    raw isa Symbol && return raw in _KIT_STOP_OUTCOMES ? raw : nothing
    raw isa AbstractString || return nothing
    s = String(raw)
    return s in ("within_grace", "sigterm", "sigkill", "no_sigint") ? Symbol(s) : nothing
end

"""
Shared run outcome (`ok`, `kind`, dirs, `failed_step`, `exit_code`, `hosts`, `stop`).

`kind` is `:go`, `:drive`, `:ride`, or `:pipeline`. Convert with [`kit_run_result`](@ref).
`hosts` is post-run collect ([`HostRunResult`](@ref)); empty for `go`, hung
`wait`, or a `drive` that never collected.

`stop` is the [`terminate!`](@ref) / [`terminate_run!`](@ref) ladder outcome.
`nothing` on a run that was not stopped that way. `:within_grace` means one
SIGINT was sent and the process was gone before SIGTERM, so workers had that
`interrupt_grace` window. `:sigterm` and `:sigkill` mean that window ended
and the ladder escalated. `:no_sigint` means `interrupt_grace` was 0, so
SIGINT was not sent and the ladder went to SIGTERM (then SIGKILL if the
process was still alive). The same string is `stop` in `kit.result`. When
the kit run directory already has this package's `run.toml`, `stop` is set
there too. `schema` stays 1. An unknown `stop` string is ignored.

`run_dir` is this run's `DISTSSHKIT_RUN_DIR` when one is known. Read it
with [`result_run_dir`](@ref). [`result_provenance`](@ref) reads
`run.toml` from it. [`result_content_tree_hash`](@ref) and
[`result_remote_run_id`](@ref) read `provenance.shipped` in that file.
A [`RideResult`](@ref) is not accepted there; convert
it with [`kit_run_result`](@ref) first.

Result fields and positional constructors are not API. Result structs are
not a stable serialization format. `serialize` and JLD2 of a result are
unsupported. The supported record is `kit.result`.
"""
struct KitRunResult
    ok::Bool
    kind::Symbol
    output_dir::Union{Nothing, String}
    log_dir::Union{Nothing, String}
    failed_step::Union{Nothing, String}
    exit_code::Int
    hosts::Vector{HostRunResult}
    tokens::Vector{String}
    stop::Union{Nothing, Symbol}
    run_dir::Union{Nothing, String}
    function KitRunResult(
            ok::Bool,
            kind::Symbol,
            output_dir::Union{Nothing, String},
            log_dir::Union{Nothing, String},
            failed_step::Union{Nothing, String},
            exit_code::Integer,
            hosts::AbstractVector{HostRunResult} = HostRunResult[],
            tokens::AbstractVector{<:AbstractString} = String[],
            stop::Union{Nothing, Symbol} = nothing;
            run_dir::Union{Nothing, AbstractString} = nothing,
        )
        parsed = _kit_stop_symbol(stop)
        stop !== nothing && parsed === nothing && throw(
            ArgumentError(
                "stop must be nothing, :within_grace, :sigterm, :sigkill, or :no_sigint, got $(repr(stop))",
            ),
        )
        return new(
            ok,
            kind,
            output_dir,
            log_dir,
            failed_step,
            Int(exit_code),
            collect(HostRunResult, hosts),
            String[String(t) for t in tokens],
            parsed,
            run_dir === nothing ? nothing : String(run_dir),
        )
    end
end

"""
Live per-host membership during a `drive` (not the post-run collect outcome).

`state` is `:joined`, `:alive`, `:left`, or `:collect_pending`.
`last_seen` is Unix time when this host last appeared in `Distributed.workers()`,
or `nothing` if it has not been observed since join.
"""
struct DriveHostStatus
    host::String
    state::Symbol
    last_seen::Union{Nothing, Float64}
end

"""
Outcome of [`drive!`](@ref) (and similar CLI steps that return an exit code).

`ok` is `true` only when the run finished with exit 0. By default that
includes the placement contract: listed `parent` / `child` hosts joined,
stayed, and collect succeeded (`require_all_hosts=true`). `require_all_hosts=false`
keeps a partial run as `ok=true`.

`output_dir` / `log_dir` are the directories actually used for this run —
resolved the same way `drive` reports `Results:` / writes its log, even when
`drive!` was not called with `output_dir=` / `log_dir=`. `nothing` when no
real run happened (e.g. built by hand) or, for `log_dir`, when logging was
disabled.

`hosts` is one [`HostRunResult`](@ref) per host that joined as a worker, in
the order results were collected. Empty when no host-collection step ran
(e.g. built by hand, or a run with no remote/local-only hosts).

`run_dir` is this run's `DISTSSHKIT_RUN_DIR` when the driver allocated one.
Read it with [`result_run_dir`](@ref). [`result_provenance`](@ref) reads
`run.toml` from it. [`result_content_tree_hash`](@ref) and
[`result_remote_run_id`](@ref) read `provenance.shipped` in that file.

Result fields and positional constructors are not API. Result structs are
not a stable serialization format. `serialize` and JLD2 of a result are
unsupported. The supported record is `kit.result`.
"""
struct DriveResult
    ok::Bool
    exit_code::Int
    output_dir::Union{Nothing, String}
    log_dir::Union{Nothing, String}
    failed_step::Union{Nothing, String}
    hosts::Vector{HostRunResult}
    run_dir::Union{Nothing, String}
    function DriveResult(
            ok::Bool,
            exit_code::Integer,
            output_dir::Union{Nothing, String},
            log_dir::Union{Nothing, String},
            failed_step::Union{Nothing, String},
            hosts::AbstractVector{HostRunResult},
            run_dir::Union{Nothing, String} = nothing,
        )
        return new(
            ok,
            Int(exit_code),
            output_dir,
            log_dir,
            failed_step,
            collect(HostRunResult, hosts),
            run_dir,
        )
    end
end

function DriveResult(
        ok::Bool,
        exit_code::Integer;
        output_dir::Union{Nothing, AbstractString} = nothing,
        log_dir::Union{Nothing, AbstractString} = nothing,
        failed_step::Union{Nothing, AbstractString} = nothing,
        hosts::AbstractVector{HostRunResult} = HostRunResult[],
        run_dir::Union{Nothing, AbstractString} = nothing,
    )
    return DriveResult(
        ok,
        Int(exit_code),
        _optional_path(output_dir),
        _optional_path(log_dir),
        failed_step === nothing ? nothing : String(failed_step),
        collect(HostRunResult, hosts),
        _optional_path(run_dir),
    )
end

"""Outcome of `collect!`."""
struct CollectResult
    ok::Bool
    exit_code::Int
end

"""
    PipelineConfig

Settings for [`pipeline!`](@ref): sync, worker tokens, driver run, and optional collect.

Worker placement uses CLI-style tokens (`parent:2`, `child:user@host:1`).
Listed tokens need `:N`. Set `sync=false` to skip sync. Set `collect=false`
to skip rsync-back. Git parity is off by default; pass `skip_hash_check=false`
(or CLI `--require-git`) to require matching remote commits.

`julia` sets the remote Julia binary (`nothing` / `"auto"` → detect; same as
CLI `--julia`). Prefer [`pipeline!(driver, workers...; …)`](@ref pipeline!) for
day-to-day use.
"""
mutable struct PipelineConfig
    project::String
    tokens::Vector{String}
    remote::Union{Nothing, String}
    hosts_file::Union{Nothing, String}
    quiet::Bool
    verbosity::Union{Nothing, Symbol}
    yes::Bool
    driver::String
    args::Vector{String}
    sync::Union{Symbol, Bool, Nothing}
    skip_hash_check::Union{Nothing, Bool}
    collect_spec::Union{Symbol, Bool, AbstractString, Nothing}
    collect_merge::Bool
    output_dir::Union{Nothing, String}
    enable_log::Bool
    log_dir::Union{Nothing, String}
    package::Union{Nothing, String}
    julia::Union{Nothing, String}
end

function PipelineConfig(;
        project::AbstractString = pwd(),
        workers::AbstractVector{<:AbstractString} = String[],
        remote::Union{Nothing, AbstractString} = nothing,
        hosts_file::Union{Nothing, AbstractString} = nothing,
        quiet::Bool = false,
        verbosity::Union{Nothing, Symbol} = nothing,
        yes::Bool = true,
        driver::AbstractString,
        args::AbstractVector{<:AbstractString} = String[],
        sync::Union{Symbol, Bool, Nothing} = nothing,
        skip_hash_check::Union{Nothing, Bool} = nothing,
        collect::Union{Symbol, Bool, AbstractString, Nothing} = nothing,
        collect_merge::Bool = false,
        output_dir::Union{Nothing, AbstractString} = nothing,
        enable_log::Bool = true,
        log_dir::Union{Nothing, AbstractString} = nothing,
        package::Union{Nothing, AbstractString} = nothing,
        julia::Union{Nothing, AbstractString} = nothing,
    )
    rr = remote === nothing ? nothing : String(strip(String(remote)))
    rr !== nothing && isempty(rr) && (rr = nothing)
    hf = hosts_file === nothing ? nothing : String(strip(String(hosts_file)))
    hf !== nothing && isempty(hf) && (hf = nothing)
    od = output_dir === nothing ? nothing : String(output_dir)
    ld = log_dir === nothing ? nothing : String(log_dir)
    pkg = package === nothing ? nothing : String(package)
    jl = if julia === nothing || isempty(strip(String(julia))) ||
            lowercase(strip(String(julia))) == "auto"
        nothing
    else
        String(julia)
    end
    return PipelineConfig(
        canonical_local_path(project),
        String[String(t) for t in workers],
        rr,
        hf,
        quiet,
        verbosity,
        yes,
        String(driver),
        Base.collect(String, args),
        sync,
        skip_hash_check,
        collect,
        collect_merge,
        od,
        enable_log,
        ld,
        pkg,
        jl,
    )
end

"""Combined outcome of [`pipeline!`](@ref). On failure, `failed_step` names the step that stopped."""
struct PipelineResult
    ok::Bool
    sync::Union{Nothing, SyncResult}
    plan::Union{Nothing, WorkerPlan}
    drive::Union{Nothing, DriveResult}
    collect::Union{Nothing, CollectResult}
    driver::String
    failed_step::Union{Nothing, String}
    output_dir::Union{Nothing, String}
    log_dir::Union{Nothing, String}
    exit_code::Int
end

function _result_exit_code(
        ok::Bool,
        drive::Union{Nothing, DriveResult},
        collect::Union{Nothing, CollectResult},
        failed_step::Union{Nothing, AbstractString} = nothing,
    )::Int
    ok && return 0
    step = failed_step === nothing ? nothing : String(failed_step)
    if step in ("run", "drive") && drive !== nothing
        return drive.exit_code
    end
    if step == "collect" && collect !== nothing
        return collect.exit_code
    end
    collect !== nothing && !collect.ok && return collect.exit_code
    drive !== nothing && !drive.ok && return drive.exit_code
    return 1
end

function PipelineResult(
        ok::Bool,
        sync::Union{Nothing, SyncResult},
        plan::Union{Nothing, WorkerPlan},
        drive::Union{Nothing, DriveResult},
        collect::Union{Nothing, CollectResult},
        driver::String;
        failed_step::Union{Nothing, String} = nothing,
        output_dir::Union{Nothing, AbstractString} = nothing,
        log_dir::Union{Nothing, AbstractString} = nothing,
        exit_code::Union{Nothing, Integer} = nothing,
    )
    od = _optional_path(output_dir)
    ld = _optional_path(log_dir)
    if drive !== nothing
        od === nothing && (od = drive.output_dir)
        ld === nothing && (ld = drive.log_dir)
    end
    code = exit_code === nothing ? _result_exit_code(ok, drive, collect, failed_step) : Int(exit_code)
    return PipelineResult(ok, sync, plan, drive, collect, driver, failed_step, od, ld, code)
end

"""Build [`KitRunResult`](@ref) from a kit outcome (`:go` / `:ride` / `:drive` / `:pipeline`)."""
function kit_run_result(result::DriveResult)::KitRunResult
    return KitRunResult(
        result.ok,
        :drive,
        result.output_dir,
        result.log_dir,
        result.failed_step,
        result.exit_code,
        result.hosts;
        run_dir = result.run_dir,
    )
end

function kit_run_result(result::PipelineResult)::KitRunResult
    return KitRunResult(
        result.ok,
        :pipeline,
        result.output_dir,
        result.log_dir,
        result.failed_step,
        result.exit_code,
    )
end

function _report_run_label(kind::Symbol)::String
    return kind === :pipeline ? "pipeline!" : String(kind)
end

function _report_run_header!(io::IO, result::KitRunResult)
    step = something(result.failed_step, "unknown")
    println(io, "$(_report_run_label(result.kind)) failed at step: $step")
    if result.output_dir !== nothing
        println(io, "  output: $(result.output_dir)")
    end
    if result.log_dir !== nothing
        println(io, "  log: $(result.log_dir)")
    end
    return nothing
end

function _report_sync_host_errors!(io::IO, sync::Union{Nothing, SyncResult})
    sync === nothing && return
    sync.ok && return
    for hr in sync.hosts
        !hr.ok && println(io, "  sync $(hr.host): $(hr.message)")
    end
    return nothing
end

"""
    report_run_errors(result; io=stderr)

Print a short summary when a kit run failed. Accepts [`KitRunResult`](@ref)
or a typed outcome (`GoResult` / `RideResult` / `DriveResult` / `PipelineResult`).
Returns `result.ok`.
"""
function report_run_errors(result::KitRunResult; io::IO = stderr)::Bool
    result.ok && return true
    _report_run_header!(io, result)
    if result.exit_code != 0
        println(io, "  exit $(result.exit_code)")
    end
    return false
end

function report_run_errors(result::DriveResult; io::IO = stderr)::Bool
    return report_run_errors(kit_run_result(result); io = io)
end

"""Build `drive` host specs from a [`WorkerPlan`](@ref)."""
function drive_host_specs(plan::WorkerPlan)::Vector{String}
    specs = String[]
    if plan.parent_workers > 0
        push!(specs, format_placement_token(:parent, PARENT_HOST_NAME, plan.parent_workers))
    end
    for (host, n) in plan.child_workers
        n > 0 && push!(specs, format_placement_token(:child, host, n))
    end
    return specs
end

function SyncResult(
        cancelled::Bool,
        host_results::Vector{HostResult};
        ok::Union{Nothing, Bool} = nothing,
        warnings::Vector{SetupWarning} = SetupWarning[],
        content_tree_hash::Union{Nothing, String} = nothing,
        run_id::Union{Nothing, String} = nothing,
    )
    if ok === nothing
        ok = !cancelled && all(hr.ok for hr in host_results)
    end
    return SyncResult(
        ok, host_results, cancelled, warnings, content_tree_hash, run_id,
    )
end
