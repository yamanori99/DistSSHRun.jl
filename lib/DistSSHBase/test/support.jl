# Shared by DistSSHBase's own tests.
# The guard skips a second definition if a parent file included this first.

if !isdefined(Main, :_with_tempdir)
    # macOS can throw ENOTEMPTY while removing a `.git` that was just written.
    function _rm_tempdir!(path::AbstractString)
        pauses = (0.05, 0.2, 0.5)
        for pause in pauses
            try
                rm(path; recursive = true, force = true)
                return nothing
            catch e
                if !(e isa Base.IOError && e.code == Base.UV_ENOTEMPTY)
                    rethrow()
                end
                sleep(pause)
            end
        end
        rm(path; recursive = true, force = true)
        return nothing
    end

    # Isolated temp directory removed after `f(path)` returns.
    function _with_tempdir(f::Function)
        path = abspath(string(mktempdir()))
        try
            return f(path)
        finally
            _rm_tempdir!(path)
        end
    end

    # Poll until `ready` holds a pid, then signal that process.
    function _kill_ready_child(ready::AbstractString; signal::Integer = Base.SIGTERM)
        t0 = time()
        pid = nothing
        while time() - t0 < 20
            if isfile(ready)
                pid = tryparse(Int, strip(read(ready, String)))
                pid === nothing || break
            end
            sleep(0.02)
        end
        pid === nothing && error("timed out waiting for $(ready)")
        ccall(:kill, Cint, (Cint, Cint), Cint(pid), Cint(signal)) == 0 ||
            error("kill $(pid) failed")
        return pid
    end

    function _run_subprocess(cmd::Cmd)
        out = IOBuffer()
        proc = run(pipeline(ignorestatus(cmd), stdout = out, stderr = out), wait = true)
        return proc, String(take!(out))
    end

    function _fake_setup_remote_env(state_dir)::Dict{String, String}
        fixtures = joinpath(@__DIR__, "fixtures")
        return Dict{String, String}(
            "DISTSSH_TEST" => "1",
            "DISTSSH_TEST_SSH" => joinpath(fixtures, "fake_setup_ssh.jl"),
            "DISTSSH_TEST_STATE_ROOT" => abspath(string(state_dir)),
            "DISTSSH_YES" => "1",
            # Absolute fake remotes are not a real git tree. Snapshot unit tests
            # that need a real Project.toml probe use `fake_snapshot_ssh.jl`.
            "DISTSSH_TEST_SNAP_GIT_YES" => "1",
        )
    end
end
