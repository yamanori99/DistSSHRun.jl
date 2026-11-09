#!/usr/bin/env julia
# Test double for snapshot-selection probes (`DISTSSHKIT_TEST_SSH`).
# Runs `__DSR_SNAP_COMPLETE__` / `__DSR_SNAP_GIT__` locally; other commands stay short.

host = length(ARGS) >= 1 ? ARGS[1] : ""
script = length(ARGS) >= 2 ? ARGS[2] : ""
logical = strip(get(ENV, "DISTSSHKIT_TEST_SSH_LOGICAL_ROOT", ""))
host_roots = strip(get(ENV, "DISTSSHKIT_TEST_SSH_HOST_ROOTS", ""))
if !isempty(logical) && !isempty(host_roots) && !isempty(host)
    host_fs = joinpath(host_roots, host)
    script = replace(script, logical => host_fs)
end
logp = get(ENV, "DISTSSHKIT_TEST_SSH_LOG", "")
if !isempty(logp)
    open(logp, "a") do io
        println(io, "HOST ", host)
        println(io, script)
        println(io, "---")
    end
end

if get(ENV, "DISTSSHKIT_TEST_SSH_FAIL", "") == "1"
    println(stderr, "Permission denied (publickey).")
    exit(255)
end

if occursin("__DSR_POSIX_OK_", script) && occursin("case x in x)", script)
    m = match(r"__DSR_POSIX_OK_[0-9a-fA-F]+__", script)
    m === nothing && exit(1)
    println(m.match)
    exit(0)
end
if strip(script) == "echo \$SHELL"
    println("/bin/sh")
    exit(0)
end
if script == "cd -P ~ && pwd -P" || script == "cd ~ && pwd"
    println(get(ENV, "DISTSSHKIT_TEST_REMOTE_HOME", "/home/distsshkit"))
    exit(0)
end
if occursin("__DSR_SNAP_COMPLETE__", script) || occursin("__DSR_SNAP_GIT__", script)
    cmd = run(pipeline(ignorestatus(`sh -c $script`); stdout = stdout, stderr = stderr); wait = true)
    exit(cmd.exitcode)
end
# Absolute deploy roots do not need further path resolve.
if occursin("pwd -P", script) || occursin("printf '%s\\n'", script)
    # Fallback: try to run path-resolve scripts that print a path.
    cmd = run(pipeline(ignorestatus(`sh -c $script`); stdout = stdout, stderr = stderr); wait = true)
    exit(cmd.exitcode)
end
exit(0)
