# Julia 1.14 delivers Ctrl-C as `Base.CancellationRequest` through the scoped
# `Base.CANCEL_TOKEN`. Julia 1.13 has neither.
const _CANCELLATION_REQUEST = isdefined(Base, :CancellationRequest) ?
    getglobal(Base, :CancellationRequest) : Union{}
const _CANCEL_TOKEN = isdefined(Base, :CANCEL_TOKEN) ? getglobal(Base, :CANCEL_TOKEN) : nothing

"""
    is_sigint(e) -> Bool

True when `e` is Ctrl-C delivered as an exception. Julia 1.13 throws
`InterruptException`. Julia 1.14 throws `Base.CancellationRequest` when
`exit_on_sigint` is off. `include` wraps either in `LoadError`, and a task
wraps it in `TaskFailedException`. Those wrappers are opened here.
"""
function is_sigint(e)::Bool
    (e isa InterruptException || e isa _CANCELLATION_REQUEST) && return true
    e isa LoadError && return is_sigint(e.error)
    e isa TaskFailedException && return is_sigint(e.task.exception)
    e isa CompositeException && return any(is_sigint, e.exceptions)
    return false
end

"""
    shield_sigint(f)

Run `f` so Ctrl-C reaches the main task, not this background task. Call it
inside the task. On Julia 1.14 this is `without_cancel`. On 1.13 it is
`disable_sigint`.
"""
function shield_sigint(f)
    _CANCEL_TOKEN === nothing && return disable_sigint(f)
    return without_cancel(f)
end

"""
    without_cancel(f)

Run `f` outside the Ctrl-C that is already being handled. On Julia 1.14 the
cancelled scope makes every later wait, write, and flush throw again, so
cleanup after Ctrl-C runs here. On 1.13 this is `f()`, and a second Ctrl-C
still stops the cleanup.
"""
function without_cancel(f)
    _CANCEL_TOKEN === nothing && return f()
    return Base.ScopedValues.with(f, _CANCEL_TOKEN => nothing)
end
