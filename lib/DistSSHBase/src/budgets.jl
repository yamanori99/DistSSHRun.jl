# Named waits. This module knows the names and how an environment value
# replaces or scales them. The caller passes the seconds.

const _WAIT_SCALE_ENV = "DISTSSHKIT_WAIT_SCALE"

# A fresh child that must print or exit, and a job that keeps running after that.
const _WAIT_RESPOND = (:child_reply, :go_job, :drive_job)

const _WAIT_STOP = (:stop_grace, :sigint_grace, :e2e_stop)

const _WAIT_LIVENESS = (:ssh_connect, :peer_silent)

function _wait_known(name::Symbol)::Bool
    name === :until_exit && return true
    return name in _WAIT_RESPOND || name in _WAIT_STOP || name in _WAIT_LIVENESS
end

# Empty or not a finite number ≥ 0 means "not set".
function _wait_env_number(key::AbstractString)::Union{Nothing, Float64}
    raw = strip(get(ENV, String(key), ""))
    isempty(raw) && return nothing
    value = tryparse(Float64, raw)
    value === nothing && return nothing
    isfinite(value) && value >= 0 || return nothing
    return Float64(value)
end

function _wait_scale()::Float64
    value = _wait_env_number(_WAIT_SCALE_ENV)
    value === nothing && return 1.0
    value > 0 || return 1.0
    return value
end

"""
    wait_seconds(name::Symbol, default::Real) -> Float64

Resolve a named wait. `default` is the caller's seconds. This module does not
choose them.

`:until_exit` returns `Inf` and ignores `default`. For any other known name,
`DISTSSHKIT_WAIT_<NAME>` wins when it is a finite number ≥ 0. An unreadable
value is ignored. `DISTSSHKIT_WAIT_SCALE` then multiplies `:child_reply`,
`:go_job`, and `:drive_job` only. Scale `1` is used when that variable is
missing, unreadable, or `0`.
"""
function wait_seconds(name::Symbol, default::Real)::Float64
    _wait_known(name) || throw(ArgumentError("unknown wait name: $name"))
    name === :until_exit && return Inf
    override = _wait_env_number("DISTSSHKIT_WAIT_" * uppercase(String(name)))
    override !== nothing && return override
    seconds = Float64(default)
    name in _WAIT_RESPOND || return seconds
    return seconds * _wait_scale()
end
