# Install and control the worker module via Core.eval / include_string.
# Return nothing so ClusterSerializer never sees DistSSHHeartbeat types.

function _remote_eval_nothing(pid::Integer, ex)
    remotecall_fetch(Core.eval, Int(pid), Main, Expr(:block, ex, nothing))
    return nothing
end

function _remote_include_nothing(pid::Integer, src::AbstractString)
    remotecall_fetch(
        Core.eval,
        Int(pid),
        Main,
        Expr(
            :block,
            Expr(:call, GlobalRef(Base, :include_string), Main, String(src)),
            nothing,
        ),
    )
    return nothing
end

function _install_boot_source()::String
    return string(
        "let\n",
        "    src = ",
        repr(WORKER_SOURCE),
        "\n",
        "    ver = v\"",
        HEARTBEAT_CODE_VERSION,
        "\"\n",
        "    if isdefined(Main, :DistSSHHeartbeat)\n",
        "        old = Main.DistSSHHeartbeat\n",
        "        try\n",
        "            isdefined(old, :stop_heartbeat_monitor) && Base.invokelatest(old.stop_heartbeat_monitor)\n",
        "        catch\n",
        "        end\n",
        "        same = isdefined(old, :HEARTBEAT_CODE_VERSION) && old.HEARTBEAT_CODE_VERSION == ver\n",
        "        same || include_string(Main, src)\n",
        "    else\n",
        "        include_string(Main, src)\n",
        "    end\n",
        "    nothing\n",
        "end\n",
    )
end

"""Eval `WORKER_SOURCE` on `pids` and start the monitor. Never pid 1."""
function install_and_start_heartbeat!(pids; interval, deadline)
    boot = _install_boot_source()
    iv = Float64(interval)
    dl = Float64(deadline)
    for w in pids
        Int(w) == 1 && continue
        _remote_include_nothing(w, boot)
        _remote_eval_nothing(
            w,
            :(Base.invokelatest(Main.DistSSHHeartbeat.start_heartbeat_monitor, $iv, $dl)),
        )
    end
    return nothing
end

function stop_heartbeat_on_workers!(pids)
    for w in pids
        Int(w) == 1 && continue
        try
            _remote_eval_nothing(
                w,
                :(
                    if isdefined(Main, :DistSSHHeartbeat) &&
                            isdefined(Main.DistSSHHeartbeat, :stop_heartbeat_monitor)
                        Base.invokelatest(Main.DistSSHHeartbeat.stop_heartbeat_monitor)
                    end
                ),
            )
        catch
        end
    end
    return nothing
end
