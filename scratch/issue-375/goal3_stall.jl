# Goal 3 / plan item 4: worker does not yield longer than the deadline,
# then resumes while the master is healthy. Expect a false-positive exit
# with the current _run_heartbeat! (watchdog vs last_pong, no stall reset).

using Distributed

# Copy of current `_run_heartbeat!` (heartbeat.jl) without DistSSHBase.
_master_alive(last_pong::Real, deadline::Real, now::Real = time()) = (now - last_pong) <= deadline
function _run_heartbeat!(
        stop::Ref{Bool},
        interval,
        deadline;
        ping = () -> remotecall_fetch(() -> true, 1),
        clock = time,
        on_dead = () -> exit(0),
    )
    last_pong = Ref(clock())
    prober = @async while !stop[]
        try
            ping()
            last_pong[] = clock()
        catch
        end
        stop[] && break
        sleep(interval)
    end
    watchdog = @async while !stop[]
        sleep(interval)
        stop[] && break
        _master_alive(last_pong[], deadline, clock()) || (on_dead(); break)
    end
    return (; prober, watchdog, last_pong)
end

addprocs(1)
w = workers()[1]
println("julia=", VERSION, " worker=", w, " threads=", Threads.nthreads())

interval = 1.0
deadline = 5.0
busy_s = 8.0

hb_src = """
_master_alive(last_pong::Real, deadline::Real, now::Real = time()) = (now - last_pong) <= deadline
function _run_heartbeat!(
        stop::Ref{Bool},
        interval,
        deadline;
        ping = () -> remotecall_fetch(() -> true, 1),
        clock = time,
        on_dead = () -> exit(0),
    )
    last_pong = Ref(clock())
    prober = @async while !stop[]
        try
            ping()
            last_pong[] = clock()
        catch
        end
        stop[] && break
        sleep(interval)
    end
    watchdog = @async while !stop[]
        sleep(interval)
        stop[] && break
        _master_alive(last_pong[], deadline, clock()) || (on_dead(); break)
    end
    return (; prober, watchdog, last_pong)
end
"""

boot = """
include_string(Main, $(repr(hb_src)))
const HEARTBEAT_STOP = Ref(false)
const HEARTBEAT_DEAD = Ref(false)
const HEARTBEAT_DEAD_AT = Ref(0.0)
function start_hb()
    myid() == 1 && return
    _run_heartbeat!(
        HEARTBEAT_STOP,
        $interval,
        $deadline;
        ping = () -> remotecall_fetch(myid, 1),
        on_dead = () -> (HEARTBEAT_DEAD[] = true; HEARTBEAT_DEAD_AT[] = time(); nothing),
    )
    return nothing
end
"""

remotecall_fetch(w, boot) do b
    include_string(Main, b)
    Base.invokelatest(Main.start_hb)
    return nothing
end

println("started heartbeat interval=$interval deadline=$deadline")
# Let a couple of successful pings land.
sleep(2.5)
alive_before = remotecall_fetch(w) do
    (Main.HEARTBEAT_DEAD[], Main.HEARTBEAT_STOP[])
end
println("before stall dead=", alive_before)

t0 = time()
println("busy-wait $busy_s s on worker (no yield)...")
remotecall_fetch(w, busy_s) do secs
    t_end = time() + secs
    while time() < t_end
        # spin; do not yield
    end
    return nothing
end
busy_elapsed = time() - t0
println("busy-wait returned after ", round(busy_elapsed; digits = 2), "s")

# Give the scheduler a few intervals to run watchdog/prober after resume.
sleep(3.0)
dead_after = remotecall_fetch(w) do
    (
        dead = Main.HEARTBEAT_DEAD[],
        dead_at = Main.HEARTBEAT_DEAD_AT[],
        nprocs = nprocs(),
        myid = myid(),
    )
end
println("after resume: ", dead_after)
if dead_after.dead
    println("FALSE POSITIVE: watchdog fired after stall while master is healthy")
else
    println("NO false positive in this run (scheduler order may vary)")
end

# Worker process still there?
println("workers after=", workers())

rmprocs(workers())
println("done")
