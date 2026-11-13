# Drive worker heartbeat policy (controller/master silence self-exit).
# Resolve once per drive invocation; do not re-read ENV downstream.

const _PROVENANCE_HEARTBEAT = Ref{Union{Nothing, Dict{String, Any}}}(nothing)

const UNSAFE_MASTER_SILENCE_EXIT_ENV = "DISTSSH_UNSAFE_MASTER_SILENCE_EXIT"
const UNSAFE_MASTER_SILENCE_EXIT_FLAG = "--unsafe-master-silence-exit"

const _HEARTBEAT_DEADLINE_ENV = "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC"
const _HEARTBEAT_INTERVAL_ENV = "DISTRIBUTED_HEARTBEAT_INTERVAL_SEC"

"""Plain summary line when self-exit is off (also written to the kit log)."""
const HEARTBEAT_SELF_EXIT_OFF_LINE =
    "Workers will not self-exit when the controller (master) is unresponsive."

function _heartbeat_unsafe_summary_line(interval::Real, deadline::Real)::String
    return "unsafe: master_silence_exit(deadline=$(deadline)s, interval=$(interval)s)"
end

"""
    explain_heartbeat_missing_deadline(; surface=:cli) -> String

Opt-in is on but `DISTRIBUTED_HEARTBEAT_DEADLINE_SEC` is missing or not positive.
"""
function explain_heartbeat_missing_deadline(; surface::Symbol = :cli)::String
    surface in (:cli, :api) || throw(ArgumentError("surface must be :cli or :api"))
    env = _HEARTBEAT_DEADLINE_ENV
    cli = UNSAFE_MASTER_SILENCE_EXIT_FLAG
    if surface === :cli
        return string(
            "drive: ",
            cli,
            " (or ",
            UNSAFE_MASTER_SILENCE_EXIT_ENV,
            "=1) requires a positive ",
            env,
            " (seconds). ",
            "There is no default deadline. ",
            "Set ",
            env,
            " before starting drive ",
            "(for example ",
            env,
            "=3600).",
        )
    end
    return string(
        "unsafe_master_silence_exit requires a positive ",
        env,
        " in the controller process environment. ",
        "There is no default deadline.",
    )
end

"""
    resolve_drive_heartbeat_policy(; env=ENV, self_exit=nothing)

Single resolution for drive heartbeat self-exit. Pass `self_exit=true/false` when
the caller already merged CLI and env (drive argv). Omit it (`nothing`) to read
`DISTSSH_UNSAFE_MASTER_SILENCE_EXIT` from `env` (API / ride).
"""
function resolve_drive_heartbeat_policy(;
        env::AbstractDict{<:Any, <:Any} = ENV,
        self_exit::Union{Nothing, Bool} = nothing,
    )
    enabled = if self_exit !== nothing
        self_exit::Bool
    else
        _heartbeat_env_flag(UNSAFE_MASTER_SILENCE_EXIT_ENV, env)
    end
    interval = DistSSHHeartbeat._heartbeat_interval(env)
    if !enabled
        return (; self_exit = false, interval = Float64(interval), deadline = nothing)
    end
    deadline = DistSSHHeartbeat._heartbeat_deadline_explicit(env)
    deadline === nothing &&
        throw(ArgumentError(explain_heartbeat_missing_deadline(; surface = :cli)))
    return (; self_exit = true, interval = Float64(interval), deadline = Float64(deadline))
end

"""Record resolved heartbeat policy into run provenance."""
function record_heartbeat_provenance!(policy)
    table = if policy.self_exit
        Dict{String, Any}(
            "self_exit" => true,
            "deadline_sec" => policy.deadline,
            "interval_sec" => policy.interval,
        )
    else
        Dict{String, Any}("self_exit" => false)
    end
    _PROVENANCE_HEARTBEAT[] = table
    return nothing
end

function write_heartbeat_startup_summary!(policy)
    if policy.self_exit
        deadline = policy.deadline
        deadline === nothing &&
            throw(ArgumentError("heartbeat policy self_exit requires a positive deadline"))
        line = _heartbeat_unsafe_summary_line(policy.interval, deadline)
        @warn line
        writeln_both(line)
    else
        writeln_both(HEARTBEAT_SELF_EXIT_OFF_LINE)
    end
    return nothing
end

function _heartbeat_env_flag(name::AbstractString, env::AbstractDict{<:Any, <:Any})::Bool
    raw = strip(get(env, String(name), ""))
    return raw in ("1", "true", "yes", "on")
end
