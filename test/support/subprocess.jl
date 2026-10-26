if !isdefined(Main, :_child_julia_env)

    # ENV for child `julia` / `drive` processes.
    #
    # Drop `Pkg.test`'s `JULIA_LOAD_PATH` so `--project=` resolves packages (and
    # stdlibs like Serialization) like a normal user invocation.
    function _child_julia_env(extra::AbstractDict = Dict{String, String}())
        # In-process `_run_kit_cli_script` sets DISTSSHKIT_CLI_SUBCOMMAND_DONE so a
        # nested `main` does not run twice. Children must not inherit that, or
        # `DistSSHRun.main` / `-m DistSSHRun` returns 0 with empty output.
        skip = Set(
            (
                "JULIA_LOAD_PATH",
                "DISTSSHKIT_CLI_SUBCOMMAND_DONE",
                "DIST_SSH_KIT_CLI_INCLUDE",
            )
        )
        env = Dict{String, String}(
            String(k) => String(v) for (k, v) in ENV if !isempty(v) && !(String(k) in skip)
        )
        env["JULIA_PKG_PRECOMPILE_AUTO"] = get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", "0")
        # Avoid broad pkill in drive; each child cleans its own workers via rmprocs.
        env["DISTSSHKIT_SKIP_GLOBAL_WORKER_PKILL"] = "1"
        for (k, v) in extra
            env[String(k)] = String(v)
        end
        return env
    end

    # How many child processes `_run_subprocesses` starts at once.
    # A function, not a `const` inside this `if`: JETLS reports that `const` as an undefined global.
    _subprocess_width() = 4

    # One child, still running. Caller closes the write end so `read` ends at exit.
    #
    # `pipeline` is a `CmdRedirect` (`cmd::AbstractCmd`), so `run` also infers
    # `ProcessChain` and `Vector{Process}`. A `Cmd` with stdio args is a `Process`,
    # which has `exitcode`. `RawFD(0)` is the stdin `pipeline` leaves inherited.
    function _start_subprocess(cmd::Cmd)
        out = Pipe()
        proc = run(ignorestatus(cmd), RawFD(0), out, out; wait = false)
        close(out.in)
        return proc, @async read(out, String)
    end

    # Run `cmds` `_subprocess_width()` at a time. Result `i` is command `i`.
    # `:until_exit`: each child runs until it exits. Drive and e2e outlast one
    # cold compile, so this does not take `:child_reply`.
    function _run_subprocesses(cmds::AbstractVector{<:Cmd})
        seconds = DistSSHRun.DistSSHBase.wait_seconds(:until_exit, 0)
        isfinite(seconds) && error("_run_subprocesses waits until exit, got $seconds")
        n = length(cmds)
        results = Vector{Tuple{Base.Process, String}}(undef, n)
        width = _subprocess_width()
        i = 1
        while i <= n
            last = min(i + width - 1, n)
            started = map(i:last) do k
                proc, reader = _start_subprocess(cmds[k])
                return (k, proc, reader)
            end
            for (k, proc, reader) in started
                wait(proc)
                results[k] = (proc, fetch(reader))
            end
            i = last + 1
        end
        return results
    end


    # Assert subprocess exit code 0; on failure print captured output first.
    function _assert_proc_ok(proc, combined::AbstractString; label::AbstractString = "subprocess")
        if proc.exitcode != 0
            println(stderr, "──── $(label) failed (exit=$(proc.exitcode)) ────")
            println(stderr, combined)
            println(stderr, "──── end $(label) output ────")
        end
        return @test proc.exitcode == 0
    end

end
