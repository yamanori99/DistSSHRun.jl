# Named waits. This module knows the names and how an environment value
# replaces or scales them. The caller passes the seconds.

const _WAIT_SCALE_ENV = "DISTSSH_WAIT_SCALE"

const _WAIT_ENV = Dict{Symbol, String}(
    :child_reply => "DISTSSH_WAIT_CHILD_REPLY",
    :go_job => "DISTSSH_WAIT_GO_JOB",
    :drive_job => "DISTSSH_WAIT_DRIVE_JOB",
    :stop_grace => "DISTSSH_WAIT_STOP_GRACE",
    :sigint_grace => "DISTSSH_WAIT_SIGINT_GRACE",
    :e2e_stop => "DISTSSH_WAIT_E2E_STOP",
    :ssh_connect => "DISTSSH_WAIT_SSH_CONNECT",
    :ssh_auth => "DISTSSH_WAIT_SSH_AUTH",
    :peer_silent => "DISTSSH_WAIT_PEER_SILENT",
)

# A fresh child that must print or exit, and a job that keeps running after that.
const _WAIT_RESPOND = (:child_reply, :go_job, :drive_job)

const _WAIT_STOP = (:stop_grace, :sigint_grace, :e2e_stop)

const _WAIT_LIVENESS = (:ssh_connect, :ssh_auth, :peer_silent)

function _wait_known(name::Symbol)::Bool
    name === :until_exit && return true
    return name in _WAIT_RESPOND || name in _WAIT_STOP || name in _WAIT_LIVENESS
end

function _wait_env_number(key::AbstractString)::Union{Nothing, Float64}
    haskey(ENV, String(key)) || return nothing
    raw = String(get(ENV, String(key), ""))
    isempty(strip(raw)) && return nothing
    return parse_env_float(key, raw; default = nothing, nonnegative = true)
end

function _wait_scale()::Float64
    haskey(ENV, _WAIT_SCALE_ENV) || return 1.0
    raw = String(get(ENV, _WAIT_SCALE_ENV, ""))
    isempty(strip(raw)) && return 1.0
    return parse_env_float(_WAIT_SCALE_ENV, raw; default = 1.0, positive = true)
end

"""
    wait_seconds(name::Symbol, default::Real) -> Float64

Resolve a named wait. `default` is the caller's seconds. This module does not
choose them.

`:until_exit` returns `Inf` and ignores `default`. For any other known name,
the matching wait environment variable wins when it is a finite number ≥ 0.
An unreadable value is an error that names the variable. `DISTSSH_WAIT_SCALE`
then multiplies `:child_reply`, `:go_job`, and `:drive_job` only. Scale `1`
is used when that variable is missing.
"""
function wait_seconds(name::Symbol, default::Real)::Float64
    _wait_known(name) || throw(ArgumentError("unknown wait name: $name"))
    name === :until_exit && return Inf
    override = _wait_env_number(_WAIT_ENV[name])
    override !== nothing && return override
    seconds = Float64(default)
    name in _WAIT_RESPOND || return seconds
    return seconds * _wait_scale()
end
