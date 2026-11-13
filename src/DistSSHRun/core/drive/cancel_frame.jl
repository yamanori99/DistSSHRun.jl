# One drive boundary for Ctrl-C.
#
# The outer dynamic scope does not see the captured cancellation token, so
# cleanup (`finally`) can write, wait, and restore. The driver body re-enters
# that same token, so Ctrl-C still interrupts `pmap`. This does not call
# `without_cancel` around the whole frame, and it does not clear or consume
# the cancellation source.
#
# Julia 1.14+ has `Base.CANCEL_TOKEN` / `CancellationRequest`. Julia 1.13 does
# not: those shims are `f()` / `false`.
#
# A second Ctrl-C during cleanup exits 130 and prints one line. Julia 1.13
# installs that with `signal`. The handler must not call `jl_exit`: that
# is not async-signal-safe, and on macOS 1.13 it can keep running worker
# teardown, then SIGSEGV, so the wait status is not 130. `_exit` skips
# atexit. Julia 1.14 owns SIGINT in its listener; `signal` and
# `exit_on_sigint` there either drop the listener or deadlock in
# `jl_exit_thread0`. The 1.14 press cancels a fresh episode, and a task
# bound to that episode calls `jl_exit`.

const _DRIVE_INTERRUPTED = Ref(false)
const _DRIVE_FRAME_DEPTH = Ref(0)
const _FRAME_CANCEL_TOKEN = Ref{Any}(nothing)
const _SECOND_SIGINT_ARMED = Ref(false)
const _SECOND_SIGINT_BYTES = UInt8[]
const _OLD_SIGINT_HANDLER = Ref{Ptr{Cvoid}}(C_NULL)
# Julia 1.13 delivers SIGINT to whichever thread is outside `sigatomic`.
# A libuv helper that runs the Julia handler segfaults. Block SIGINT on those
# helpers and wake the drive task from the event loop. 1.14 uses the token.
const _JULIA_SIGINT_HANDLER = Ref{Ptr{Cvoid}}(C_NULL)
const _MAIN_SIGINT_INSTALLED = Ref(false)
const _MAIN_SIGINT_TASK = Ref{Any}(nothing)
const _MAIN_SIGINT_ASYNC = Ref{Any}(nothing)
const _MAIN_HANDLE = Ref{Ptr{Cvoid}}(C_NULL)
const _POOL_SIGINT_BLOCKED = Ref(false)
const _SECOND_WATCH_STARTED = Ref(false)
const _SAVED_SIGINT_EPISODE = Ref{Any}(nothing)

"""Process-wide: a drive Ctrl-C has been accepted. `main` reads this."""
function _mark_interrupted!()
    _DRIVE_INTERRUPTED[] = true
    return nothing
end

_drive_was_interrupted()::Bool = _DRIVE_INTERRUPTED[]

function _clear_interrupted!()
    _DRIVE_INTERRUPTED[] = false
    return nothing
end

function _noncancellable(f)
    if isdefined(Base, :CANCEL_TOKEN)
        return Base.ScopedValues.with(f, Base.CANCEL_TOKEN => nothing)
    else
        return f()
    end
end

function _capture_cancel_token()
    if isdefined(Base, :CANCEL_TOKEN)
        return Base.CANCEL_TOKEN[]
    else
        return nothing
    end
end

function _with_captured_token(f, token)
    if isdefined(Base, :CANCEL_TOKEN)
        return Base.ScopedValues.with(f, Base.CANCEL_TOKEN => token)
    else
        return f()
    end
end

"""True when this dynamic scope's token is already cancelled."""
function _caller_token_cancelled()::Bool
    if isdefined(Base, :CANCEL_TOKEN) && isdefined(Base, :iscancelled)
        tok = Base.CANCEL_TOKEN[]
        tok isa Base.CancellationToken || return false
        return Base.iscancelled(tok)
    else
        return false
    end
end

"""
Ctrl-C, including a worker `RemoteException` raised while this task's
token is already cancelled (the worker observed the press first).
"""
function _interruptish(e)::Bool
    is_sigint(e) && return true
    _caller_token_cancelled() || return false
    return isstructtype(typeof(e)) && hasfield(typeof(e), :captured)
end

"""True only for Julia 1.14's Ctrl-C exception, not `InterruptException`."""
function _is_cancellation_request(e)::Bool
    if isdefined(Base, :CancellationRequest)
        return e isa Base.CancellationRequest
    else
        return false
    end
end

"""`InterruptException` or `CancellationRequest`, wrappers removed."""
function _bare_sigint(e)
    e isa InterruptException && return e
    _is_cancellation_request(e) && return e
    e isa LoadError && return _bare_sigint(e.error)
    e isa TaskFailedException && return _bare_sigint(e.task.exception)
    if e isa CompositeException
        for part in e.exceptions
            is_sigint(part) && return _bare_sigint(part)
        end
    end
    return e
end

function _second_sigint_message()::String
    return "Cleanup skipped after a second interrupt. Run `$(cli_m()) help drive` for flags."
end

# Installed only after the first interrupt. `write` + `_exit` (no alloc).
function _second_sigint_handler(_signum::Cint)::Cvoid
    bytes = _SECOND_SIGINT_BYTES
    if !isempty(bytes)
        ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, pointer(bytes), sizeof(bytes))
    end
    return ccall(:_exit, Union{}, (Cint,), Cint(130))
end

# Created at runtime. A top-level `@cfunction` is baked into the package image
# and is not a valid handler after load.
const _SECOND_SIGINT_CFUN = Ref{Ptr{Cvoid}}(C_NULL)

# `signal` returns `SIG_ERR` on failure. `C_NULL` is `SIG_DFL`, a real disposition.
const _SIG_ERR = reinterpret(Ptr{Cvoid}, -1)

function _second_sigint_cfun()::Ptr{Cvoid}
    ptr = _SECOND_SIGINT_CFUN[]
    ptr == C_NULL || return ptr
    ptr = @cfunction(_second_sigint_handler, Cvoid, (Cint,))
    _SECOND_SIGINT_CFUN[] = ptr
    return ptr
end

"""First Ctrl-C: remember it, and make the next Ctrl-C exit 130 immediately."""
function _accept_drive_sigint!()
    _mark_interrupted!()
    _arm_second_sigint!()
    return nothing
end

function _write_second_sigint_line()
    bytes = _SECOND_SIGINT_BYTES
    isempty(bytes) && return nothing
    GC.@preserve bytes begin
        ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, pointer(bytes), sizeof(bytes))
    end
    return nothing
end

function _second_sigint_watch()
    try
        while _SECOND_SIGINT_ARMED[]
            sleep(0.05)
        end
    catch e
        is_sigint(e) || rethrow()
        # The episode token is still cancelled. Leave it before `jl_exit`.
        _noncancellable() do
            _write_second_sigint_line()
            ccall(:jl_exit, Union{}, (Int32,), Int32(130))
        end
    end
    return nothing
end

"""
On Julia 1.14, bind one task to a fresh ^C episode so the next press exits.
Cleanup itself stays non-cancellable. No-op until the first press, and on 1.13.
"""
function _ensure_second_sigint_watch!()
    if isdefined(Base, :CANCEL_TOKEN) &&
            isdefined(Base, :sigint_new_episode!) &&
            isdefined(Base, :_sigint_episode)
        _SECOND_SIGINT_ARMED[] || return nothing
        _SECOND_WATCH_STARTED[] && return nothing
        _SECOND_WATCH_STARTED[] = true
        Base.exit_on_sigint(false)
        _SAVED_SIGINT_EPISODE[] = Base._sigint_episode[]
        tok = Base.sigint_new_episode!()
        @async Base.ScopedValues.with(_second_sigint_watch, Base.CANCEL_TOKEN => tok)
        # Reach `sleep` before cleanup blocks the scheduler in a foreign call.
        yield()
    end
    return nothing
end

function _restore_sigint_episode!()
    saved = _SAVED_SIGINT_EPISODE[]
    _SAVED_SIGINT_EPISODE[] = nothing
    saved isa Tuple || return nothing
    src = saved[1]
    if isdefined(Base, :CancellationTokenSource) &&
            isdefined(Base, :sigint_new_episode!)
        if src isa Base.CancellationTokenSource
            Base.sigint_new_episode!(src)
            return nothing
        end
    end
    if isdefined(Base, :sigint_close_episode!)
        Base.sigint_close_episode!()
    end
    return nothing
end

function _arm_second_sigint!()
    _SECOND_SIGINT_ARMED[] && return nothing
    empty!(_SECOND_SIGINT_BYTES)
    append!(_SECOND_SIGINT_BYTES, codeunits(_second_sigint_message()))
    push!(_SECOND_SIGINT_BYTES, UInt8('\n'))
    # The bytes are published before the press can exit the process.
    _SECOND_SIGINT_ARMED[] = true
    if isdefined(Base, :CANCEL_TOKEN)
        # `exit_on_sigint(true)` takes `jl_exit_thread0`, which deadlocks
        # against cleanup on this thread. Stay on the cancel path.
        Base.exit_on_sigint(false)
    else
        _block_helper_sigint!()
        # `jl_exit` from this thread deadlocks inside cleanup. Block SIGINT
        # here so the listener's thread runs the hard-exit handler.
        _block_this_thread_sigint!()
        old = ccall(
            :signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), Cint(2), _second_sigint_cfun(),
        )
        if old == _SIG_ERR
            _SECOND_SIGINT_ARMED[] = false
            return nothing
        end
        _OLD_SIGINT_HANDLER[] = old
    end
    return nothing
end

function _disarm_second_sigint!()
    _SECOND_SIGINT_ARMED[] || return nothing
    _SECOND_SIGINT_ARMED[] = false
    if isdefined(Base, :CANCEL_TOKEN)
        _SECOND_WATCH_STARTED[] = false
        _restore_sigint_episode!()
        isinteractive() || Base.exit_on_sigint(true)
        return nothing
    end
    # `C_NULL` is `SIG_DFL` and must be put back. `SIG_ERR` is never stored.
    ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), Cint(2), _OLD_SIGINT_HANDLER[])
    return nothing
end

# `SIG_BLOCK` is 0 on Linux and macOS (`signal.h`).
function _block_helper_sigint!()
    _POOL_SIGINT_BLOCKED[] && return nothing
    set = zeros(UInt8, 128)
    GC.@preserve set begin
        ccall(:sigemptyset, Cint, (Ptr{UInt8},), set)
        ccall(:sigaddset, Cint, (Ptr{UInt8}, Cint), set, Cint(2))
        # One queued call can run on a thread that already blocked it.
        # Sixteen in parallel covers libuv's pool (default 4).
        @sync for _ in 1:16
            @async @threadcall(
                :pthread_sigmask, Cint, (Cint, Ptr{UInt8}, Ptr{Cvoid}),
                Cint(0), set, C_NULL,
            )
        end
    end
    _POOL_SIGINT_BLOCKED[] = true
    return nothing
end

function _deliver_main_sigint(_cond)
    task = _MAIN_SIGINT_TASK[]
    task isa Task || return nothing
    istaskdone(task) && return nothing
    try
        schedule(task, InterruptException(); error = true)
    catch
        try
            Base.throwto(task, InterruptException())
        catch
        end
    end
    return nothing
end

# `SIG_UNBLOCK` is 1 on Linux and macOS, `SIG_BLOCK` is 0.
function _unblock_this_thread_sigint!()
    set = zeros(UInt8, 128)
    GC.@preserve set begin
        ccall(:sigemptyset, Cint, (Ptr{UInt8},), set)
        ccall(:sigaddset, Cint, (Ptr{UInt8}, Cint), set, Cint(2))
        ccall(:pthread_sigmask, Cint, (Cint, Ptr{UInt8}, Ptr{Cvoid}), Cint(1), set, C_NULL)
    end
    return nothing
end

function _block_this_thread_sigint!()
    set = zeros(UInt8, 128)
    GC.@preserve set begin
        ccall(:sigemptyset, Cint, (Ptr{UInt8},), set)
        ccall(:sigaddset, Cint, (Ptr{UInt8}, Cint), set, Cint(2))
        ccall(:pthread_sigmask, Cint, (Cint, Ptr{UInt8}, Ptr{Cvoid}), Cint(0), set, C_NULL)
    end
    return nothing
end

function _main_sigint_handler(_signum::Cint)::Cvoid
    # The drive thread is the only one with SIGINT unblocked, so this runs
    # there. A safepoint spin never polls libuv: throw into that task.
    # A different task (Distributed's reader) gets the event-loop wake instead.
    target = _MAIN_SIGINT_TASK[]
    if target isa Task && current_task() === target
        # The singleton pointer is one load out; a fresh exception is the
        # object `jl_throw` expects, and a safepoint spin can catch it.
        ccall(:jl_throw, Union{}, (Any,), InterruptException())
        return
    end
    handle = _MAIN_HANDLE[]
    handle == C_NULL && return
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), handle)
    return
end

const _MAIN_SIGINT_CFUN = Ref{Ptr{Cvoid}}(C_NULL)

function _main_sigint_cfun()::Ptr{Cvoid}
    ptr = _MAIN_SIGINT_CFUN[]
    ptr == C_NULL || return ptr
    ptr = @cfunction(_main_sigint_handler, Cvoid, (Cint,))
    _MAIN_SIGINT_CFUN[] = ptr
    return ptr
end

function _install_main_task_sigint!()
    if isdefined(Base, :CANCEL_TOKEN)
        return nothing
    end
    _MAIN_SIGINT_INSTALLED[] && return nothing
    _block_helper_sigint!()
    _unblock_this_thread_sigint!()
    _MAIN_SIGINT_TASK[] = current_task()
    cond = Base.AsyncCondition(_deliver_main_sigint)
    _MAIN_SIGINT_ASYNC[] = cond
    _MAIN_HANDLE[] = cond.handle
    old = ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), Cint(2), _main_sigint_cfun())
    if old == _SIG_ERR
        _MAIN_HANDLE[] = C_NULL
        _MAIN_SIGINT_TASK[] = nothing
        _MAIN_SIGINT_ASYNC[] = nothing
        close(cond)
        return nothing
    end
    _JULIA_SIGINT_HANDLER[] = old
    _MAIN_SIGINT_INSTALLED[] = true
    return nothing
end

function _restore_main_task_sigint!()
    _MAIN_SIGINT_INSTALLED[] || return nothing
    _MAIN_SIGINT_INSTALLED[] = false
    _MAIN_HANDLE[] = C_NULL
    if !_SECOND_SIGINT_ARMED[]
        # `C_NULL` is `SIG_DFL` and must be put back. `SIG_ERR` is never stored.
        ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), Cint(2), _JULIA_SIGINT_HANDLER[])
        # Julia's listener `sigwait`s. Leave SIGINT blocked on this thread.
        _block_this_thread_sigint!()
    end
    cond = _MAIN_SIGINT_ASYNC[]
    _MAIN_SIGINT_ASYNC[] = nothing
    _MAIN_SIGINT_TASK[] = nothing
    cond isa Base.AsyncCondition && close(cond)
    return nothing
end

"""
    _drive_cancellable(f)

Run `f` under the token captured by the enclosing [`_drive_frame`](@ref).
On Ctrl-C, accept it (second-Ctrl-C arm) and rethrow the original exception.
"""
function _drive_cancellable(f)
    _install_main_task_sigint!()
    try
        return _with_captured_token(_FRAME_CANCEL_TOKEN[]) do
            try
                return f()
            catch e
                if _interruptish(e)
                    _accept_drive_sigint!()
                end
                rethrow()
            end
        end
    finally
        # Leave the hard-exit handler in place for cleanup.
        _SECOND_SIGINT_ARMED[] || _restore_main_task_sigint!()
    end
end

"""
    _drive_frame(f; cli=false)

Outer non-cancellable scope for one drive. `f` contains setup and the
`finally` blocks (progress, log, result files, project / env restore,
`rmprocs`). Cancellable work calls [`_drive_cancellable`](@ref).

`cli=true` throws [`_DriveProcessInterrupt`](@ref) after those `finally`
blocks so `main` can `exit(130)`. Otherwise the original `InterruptException`
or `CancellationRequest` propagates. A nested call joins the outer frame.
"""
function _drive_frame(f; cli::Bool = false)
    if _DRIVE_FRAME_DEPTH[] > 0
        return f()
    end
    _DRIVE_FRAME_DEPTH[] += 1
    # A `cli=true` frame leaves the flag set for `main`. The next outermost
    # frame must not treat a later ordinary error as an interrupt.
    _clear_interrupted!()
    token = _capture_cancel_token()
    try
        return _noncancellable() do
            prev = _FRAME_CANCEL_TOKEN[]
            _FRAME_CANCEL_TOKEN[] = token
            try
                return f()
            catch e
                if is_sigint(e) || _drive_was_interrupted()
                    _drive_was_interrupted() || _accept_drive_sigint!()
                    if cli
                        throw(_DriveProcessInterrupt())
                    elseif is_sigint(e)
                        throw(_bare_sigint(e))
                    else
                        # The worker wrapper is not the caller's interrupt.
                        if isdefined(Base, :CANCEL_REQUEST_SAFE)
                            throw(Base.CANCEL_REQUEST_SAFE)
                        else
                            throw(InterruptException())
                        end
                    end
                end
                rethrow()
            finally
                _FRAME_CANCEL_TOKEN[] = prev
                # In-process callers observe the original exception themselves.
                # The CLI flag stays set so `main` can still map a leaked
                # `CancellationRequest` to exit 130.
                cli || _clear_interrupted!()
                _disarm_second_sigint!()
                _restore_main_task_sigint!()
            end
        end
    finally
        _DRIVE_FRAME_DEPTH[] -= 1
    end
end

"""
Drop Distributed's GC-message task once Ctrl-C has already failed it, so
`atexit` does not `wait` a dead task. A task that is still running is left
for Distributed. Julia 1.13 has no cancellation of that task.
"""
function _retire_distributed_gc_task!()
    if isdefined(Base, :CancellationRequest)
        isdefined(Distributed, :gc_msgs_task) || return nothing
        task = getfield(Distributed, :gc_msgs_task)
        task isa Task || return nothing
        istaskfailed(task) || return nothing
        try
            wait(task)
        catch
        end
        try
            setglobal!(Distributed, :gc_msgs_task, nothing)
        catch
        end
    end
    return nothing
end

"""
CLI translation of a drive interrupt. `exit`s 130 or 1, or returns so the
caller can rethrow. No cleanup here.
"""
function _cli_finish_interrupt(e)
    if e isa _DriveProcessInterrupt ||
            (_drive_was_interrupted() && _is_cancellation_request(e))
        exit(130)
    end
    if _is_cancellation_request(e)
        _noncancellable() do
            showerror(stderr, e)
            println(stderr)
        end
        exit(1)
    end
    return nothing
end
