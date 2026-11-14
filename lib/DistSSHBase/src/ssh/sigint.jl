# With task cancellation, Ctrl-C may throw `Base.CancellationRequest` via
# `Base.CANCEL_TOKEN` when that API exists (e.g. some 1.14 alphas; absent from
# 1.14.0-beta1 through 1.14.x after #64651). Gates on `isdefined`, not `VERSION`.
# Without it, only `InterruptException` (e.g. 1.13 and 1.14.x without the API).
const _CANCELLATION_REQUEST = isdefined(Base, :CancellationRequest) ?
    getglobal(Base, :CancellationRequest) : Union{}
const _CANCEL_TOKEN = isdefined(Base, :CANCEL_TOKEN) ? getglobal(Base, :CANCEL_TOKEN) : nothing

"""
    is_sigint(e) -> Bool

True when `e` is Ctrl-C delivered as an exception. Without task cancellation,
Julia throws `InterruptException`. With `Base.CANCEL_TOKEN`, it may throw
`Base.CancellationRequest` when `exit_on_sigint` is off. `include` wraps
either in `LoadError`, a task wraps it in `TaskFailedException`, and a worker
wraps it in `RemoteException` (`captured` / `ex`). Those wrappers are opened here.
"""
function is_sigint(e)::Bool
    (e isa InterruptException || e isa _CANCELLATION_REQUEST) && return true
    e isa LoadError && return is_sigint(e.error)
    e isa TaskFailedException && return is_sigint(e.task.exception)
    e isa CompositeException && return any(is_sigint, e.exceptions)
    if isstructtype(typeof(e))
        hasfield(typeof(e), :captured) && return is_sigint(getfield(e, :captured))
        hasfield(typeof(e), :ex) && return is_sigint(getfield(e, :ex))
    end
    return false
end

"""
    shield_sigint(f)

Run `f` so Ctrl-C reaches the main task, not this background task. Call it
inside the task. With `Base.CANCEL_TOKEN`, this is `without_cancel`. Otherwise
`disable_sigint` when `Base.CANCEL_TOKEN` is undefined.
"""
function shield_sigint(f)
    _CANCEL_TOKEN === nothing && return disable_sigint(f)
    return without_cancel(f)
end

"""
    without_cancel(f)

Run `f` outside the Ctrl-C that is already being handled. With cancellation, the
cancelled scope makes every later wait, write, and flush throw again, so
cleanup after Ctrl-C runs here. Without cancellation this is `f()`, and a second
Ctrl-C still stops the cleanup.
"""
function without_cancel(f)
    _CANCEL_TOKEN === nothing && return f()
    return Base.ScopedValues.with(f, _CANCEL_TOKEN => nothing)
end
