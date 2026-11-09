# Shared by the master package and the worker source string. Stdlib only.

_master_alive(last_pong::Real, deadline::Real, now::Real = time()) = (now - last_pong) <= deadline

"""Prober + watchdog. `ping` / `clock` / `on_dead` are injectable.

Stay on the default thread (`@async`). Do not move this to `:interactive`:
the master's reply is handled on Distributed's default-thread task.

If this process does not yield for longer than `2 * interval`, the watchdog
resets `last_pong` and does not ping (a blocking ping would hang the
watchdog). The deadline is also the maximum time the master may go
without yielding.
"""
function _run_heartbeat!(
        stop::Ref{Bool},
        interval,
        deadline;
        ping,
        clock = time,
        on_dead,
    )
    last_pong = Ref(clock())
    last_wake = Ref(clock())
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
        now = clock()
        prev_wake = last_wake[]
        last_wake[] = now
        if (now - prev_wake) > (2 * Float64(interval))
            # Worker (or this task) did not yield. Do not call `ping` here:
            # it can block the watchdog (hung master). The prober pings
            # when it runs. Reset last success so a long yield is not a
            # false-positive exit.
            last_pong[] = now
            continue
        end
        _master_alive(last_pong[], deadline, now) || (on_dead(); break)
    end
    return (; prober, watchdog, last_pong, last_wake)
end
