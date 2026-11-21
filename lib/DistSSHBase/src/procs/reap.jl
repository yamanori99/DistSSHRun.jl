# SIGKILL for pids this package listed. Ctrl-C exceptions stay in ssh/sigint.jl.

const _SIGKILL = 9
const _ESRCH = 3

function _last_errno()::Cint
    ptr = if Sys.isapple()
        ccall(:__error, Ptr{Cint}, ())
    else
        ccall(:__errno_location, Ptr{Cint}, ())
    end
    return unsafe_load(ptr)
end

function _kill_pid_noerr(pid::Integer, signum::Integer)
    pid = Int(pid)
    pid < 1 && return nothing
    ret = ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(signum))
    ret == 0 && return nothing
    _last_errno() == _ESRCH && return nothing
    return nothing
end

"""Send SIGKILL to each row. Missing processes are ignored."""
function reap!(rows::AbstractVector{ProcessRow})
    for row in rows
        _kill_pid_noerr(row.pid, _SIGKILL)
    end
    return nothing
end

"""
    wait_gone(f; timeout, pollint=0.25)

Call `f()` until it returns an empty vector or `timeout` seconds elapse.
Returns the final vector from `f()` (empty when all gone in time).
"""
function wait_gone(f::Function; timeout::Real, pollint::Real = 0.25)
    timeout > 0 || throw(ArgumentError("wait_gone: timeout must be positive"))
    pollint > 0 || throw(ArgumentError("wait_gone: pollint must be positive"))
    deadline = time() + Float64(timeout)
    rows = f()
    while !isempty(rows) && time() < deadline
        sleep(pollint)
        rows = f()
    end
    return rows
end
