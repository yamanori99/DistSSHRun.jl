# Environment names: one `DISTSSH_` prefix, fail-closed parse, no aliases.

const LEGACY_ENV_RENAMES = (
    "DISTRIBUTED_COLLECT_DIRS" => "DISTSSH_COLLECT_DIRS",
    "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC" => "DISTSSH_HEARTBEAT_DEADLINE_SEC",
    "DISTRIBUTED_HEARTBEAT_INTERVAL_SEC" => "DISTSSH_HEARTBEAT_INTERVAL_SEC",
    "DISTRIBUTED_INIT_DELAY_SEC" => "DISTSSH_INIT_DELAY_SEC",
    "DISTRIBUTED_OUTPUT_DIR" => "DISTSSH_OUTPUT_DIR",
    "DISTRIBUTED_PING_RETRIES" => "DISTSSH_PING_RETRIES",
    "DISTRIBUTED_PROJECT_ROOT" => "DISTSSH_PROJECT_ROOT",
    "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "DISTSSH_REMOTE_PROJECT_ROOT",
    "DISTRIBUTED_RUNNER" => "DISTSSH_INTERNAL_RUNNER",
    "DISTRIBUTED_SKIP_COLLECT" => "DISTSSH_SKIP_COLLECT",
    "DISTRIBUTED_SSH_OPTS" => "DISTSSH_SSH_OPTS",
)

function throw_renamed_env!(old::AbstractString, new::AbstractString)
    throw(ArgumentError(string(old, " was renamed to ", new)))
end

"""Throw when a pre-0.2.0 Distributed-prefix name is present in `env`."""
function throw_if_legacy_env!(env = ENV)
    for (old, new) in LEGACY_ENV_RENAMES
        haskey(env, old) && throw_renamed_env!(old, new)
    end
    return nothing
end

function parse_env_bool(name::AbstractString, raw::AbstractString)::Bool
    s = strip(String(raw))
    s in ("1", "true", "yes", "on") && return true
    s in ("0", "false", "no", "off") && return false
    throw(
        ArgumentError(
            "$(name) must be 1/true/yes/on or 0/false/no/off, got $(repr(String(raw)))",
        ),
    )
end

function parse_env_int(
        name::AbstractString,
        raw::AbstractString;
        default::Int,
        minimum::Int = 1,
    )::Int
    s = strip(String(raw))
    isempty(s) && return default
    n = tryparse(Int, s)
    (n === nothing || n < minimum) && throw(
        ArgumentError("$(name) must be an integer >= $(minimum), got $(repr(String(raw)))"),
    )
    return n
end

function parse_env_float(
        name::AbstractString,
        raw::AbstractString;
        default::Union{Nothing, Float64},
        positive::Bool = false,
        nonnegative::Bool = false,
    )::Union{Nothing, Float64}
    s = strip(String(raw))
    isempty(s) && return default
    v = tryparse(Float64, s)
    (v === nothing || !isfinite(v)) && throw(
        ArgumentError("$(name) must be a finite number, got $(repr(String(raw)))"),
    )
    positive && !(v > 0) && throw(
        ArgumentError("$(name) must be positive, got $(repr(String(raw)))"),
    )
    nonnegative && v < 0 && throw(
        ArgumentError("$(name) must be >= 0, got $(repr(String(raw)))"),
    )
    return Float64(v)
end

"""Test-only SSH/juliaup hooks. Product code never reads test env names."""
struct InjectedSshTransport{A, B, C, D, E, F}
    is_on::A
    remote_cmd::B
    posix_strict::C
    double_script::D
    local_juliaup::E
    remote_julia_which::F
end

const _injected_ssh = Ref{Any}(nothing)

function _test_doubles_on()::Bool
    t = _injected_ssh[]
    t === nothing && return false
    return t.is_on()::Bool
end
