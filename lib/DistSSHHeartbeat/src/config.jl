# Master-side env for worker heartbeat monitors (opt-in self-exit only).

function _heartbeat_interval(env)::Float64
    raw = haskey(env, "DISTSSH_HEARTBEAT_INTERVAL_SEC") ?
        String(get(env, "DISTSSH_HEARTBEAT_INTERVAL_SEC", "")) : ""
    v = DistSSHBase.parse_env_float(
        "DISTSSH_HEARTBEAT_INTERVAL_SEC",
        raw;
        default = 30.0,
        positive = true,
    )
    return Float64(v)
end

"""Positive `DISTSSH_HEARTBEAT_DEADLINE_SEC` only; no implicit fallback."""
function _heartbeat_deadline_explicit(env)::Union{Nothing, Float64}
    haskey(env, "DISTSSH_HEARTBEAT_DEADLINE_SEC") || return nothing
    raw = String(get(env, "DISTSSH_HEARTBEAT_DEADLINE_SEC", ""))
    isempty(strip(raw)) && return nothing
    return DistSSHBase.parse_env_float(
        "DISTSSH_HEARTBEAT_DEADLINE_SEC",
        raw;
        default = nothing,
        positive = true,
    )
end

"""Interval and an explicit deadline (caller must validate opt-in and deadline)."""
function _heartbeat_config(env = ENV; deadline::Real)
    dl = Float64(deadline)
    dl > 0 || throw(ArgumentError("heartbeat deadline must be positive"))
    return (; interval = _heartbeat_interval(env), deadline = dl)
end
