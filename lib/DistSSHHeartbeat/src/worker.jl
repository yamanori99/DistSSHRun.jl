# Worker-only body. Concatenated into WORKER_SOURCE. No DistSSHBase.

const HEARTBEAT_EXIT_CODE = 75
const HEARTBEAT_STOP = Ref{Ref{Bool}}(Ref(true))

function ping_master()
    return remotecall_fetch(myid, 1) == 1
end

function _heartbeat_die!()
    # Keep `_exit` until a Julia 1.13.x ships with Distributed.jl #198.
    Timer(10) do _
        ccall(:_exit, Cvoid, (Cint,), HEARTBEAT_EXIT_CODE)
        return
    end
    try
        @warn "DistSSHHeartbeat: master did not answer within the deadline; worker exiting" pid = myid()
    catch
    end
    exit(HEARTBEAT_EXIT_CODE)
    return
end

function stop_heartbeat_monitor()
    HEARTBEAT_STOP[][] = true
    return nothing
end

function start_heartbeat_monitor(interval, deadline)
    myid() == 1 && return nothing
    stop_heartbeat_monitor()
    token = Ref(false)
    HEARTBEAT_STOP[] = token
    _run_heartbeat!(
        token,
        interval,
        deadline;
        ping = ping_master,
        on_dead = _heartbeat_die!,
    )
    return nothing
end
