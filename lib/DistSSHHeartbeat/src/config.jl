# Master-side env. The deadline is also the longest the master may go
# without yielding: a stall longer than that is treated as silence unless
# the worker resets on its own wake gap (see monitor.jl).

# `DISTRIBUTED_HEARTBEAT_DEADLINE_SEC` wins when it is positive. Otherwise
# `:peer_silent` (600s), the same budget as SSH ServerAlive. A missing,
# unreadable, or non-positive result stays 600, including when that named
# wait itself resolves to 0.
function _heartbeat_deadline(env)::Float64
    raw = strip(get(env, "DISTRIBUTED_HEARTBEAT_DEADLINE_SEC", ""))
    parsed = isempty(raw) ? nothing : tryparse(Float64, raw)
    deadline = parsed === nothing ? DistSSHBase.wait_seconds(:peer_silent, 600) : Float64(parsed)
    return deadline > 0 ? deadline : 600.0
end

function _heartbeat_config(env = ENV)
    interval = something(tryparse(Float64, get(env, "DISTRIBUTED_HEARTBEAT_INTERVAL_SEC", "30")), 30.0)
    deadline = _heartbeat_deadline(env)
    interval > 0 || (interval = 30.0)
    return (; interval, deadline)
end
