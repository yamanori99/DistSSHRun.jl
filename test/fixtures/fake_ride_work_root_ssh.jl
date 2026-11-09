# Test double for `ssh HOST SCRIPT` (`DISTSSHKIT_TEST_SSH`).
# Runs snapshot / ship work-root probes locally. Other commands stay short.

host = length(ARGS) >= 1 ? ARGS[1] : ""
script = length(ARGS) >= 2 ? ARGS[2] : ""
logp = get(ENV, "DISTSSHKIT_TEST_SSH_LOG", "")
if !isempty(logp)
    open(logp, "a") do io
        println(io, "HOST ", host)
        println(io, script)
        println(io, "---")
    end
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
if script == "cd -P ~ && pwd -P"
    println("/home/dev")
    exit(0)
end
if script == "cd ~ && pwd"
    println("/home/dev")
    exit(0)
end
if occursin("__DSR_SHIP_SRC__", script) ||
        occursin("__DSR_SNAP_GIT__", script) ||
        occursin("__DSR_SNAP_COMPLETE__", script)
    cmd = run(pipeline(ignorestatus(`sh -c $script`); stdout = stdout, stderr = stderr); wait = true)
    exit(cmd.exitcode)
end
if occursin("joinpath(Sys.BINDIR", script)
    println("/usr/bin/julia")
    exit(0)
end
if occursin("--project=", script)
    exit(1)
end
exit(0)
