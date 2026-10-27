#!/usr/bin/env julia
# Login-shell double for the failure-time POSIX probe.
# SHELL_DOUBLE_MODE: posix (default), fish, probe255.
# SHELL_DOUBLE_NOISE=1 prints a line before the POSIX marker.
# SHELL_DOUBLE_LOG appends each remote script.

function main()
    script = length(ARGS) >= 2 ? ARGS[2] : ""
    logp = get(ENV, "SHELL_DOUBLE_LOG", "")
    if !isempty(logp)
        open(logp, "a") do io
            println(io, script)
        end
    end
    mode = get(ENV, "SHELL_DOUBLE_MODE", "posix")
    if occursin("__DSR_POSIX_OK_", script) && occursin("case x in x)", script)
        if mode == "fish"
            println(stderr, "fish: syntax error")
            exit(127)
        elseif mode == "probe255"
            exit(255)
        end
        if get(ENV, "SHELL_DOUBLE_NOISE", "") == "1"
            println("motd")
        end
        m = match(r"__DSR_POSIX_OK_[0-9a-fA-F]+__", script)
        m === nothing && exit(1)
        println(m.match)
        exit(0)
    end
    if strip(script) == "echo \$SHELL"
        if mode == "fish"
            println("banner")
            println("/usr/bin/fish")
        else
            println("/bin/sh")
        end
        exit(0)
    end
    if script == "ok"
        println("ok")
        exit(0)
    end
    if script == "sshfail"
        println(stderr, "Permission denied (publickey).")
        exit(255)
    end
    println(stderr, "missing-tool")
    return exit(9)
end

main()
