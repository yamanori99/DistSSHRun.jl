# Master-side env for worker heartbeat monitors (opt-in self-exit only).

function _heartbeat_interval(env)::Float64
    interval = something(tryparse(Float64, get(env, "DISTRIBUTED_HEARTBEAT_INTERVAL_SEC", "30")), 30.0)
    interval > 0 || (interval = 30.0)
    return Float64(interval)
end

"""Positive `DISTRIBUTED_HEARTBEAT_DEADLINE_SEC` only; no implicit fallback."""
function _heartbeat_deadline_explicit(env)::Union{Nothing, Float64}
    raw = strip(get(env, "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC", ""))
    parsed = isempty(raw) ? nothing : tryparse(Float64, raw)
    parsed === nothing && return nothing
    deadline = Float64(parsed)
    return deadline > 0 ? deadline : nothing
end

"""Interval and an explicit deadline (caller must validate opt-in and deadline)."""
function _heartbeat_config(env = ENV; deadline::Real)
    dl = Float64(deadline)
    dl > 0 || throw(ArgumentError("heartbeat deadline must be positive"))
    return (; interval = _heartbeat_interval(env), deadline = dl)
end
