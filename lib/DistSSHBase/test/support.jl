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

    function _run_subprocess(cmd::Cmd)
        out = IOBuffer()
        proc = run(pipeline(ignorestatus(cmd), stdout = out, stderr = out), wait = true)
        return proc, String(take!(out))
    end

    function _fake_setup_remote_env(state_dir)::Dict{String, String}
        fixtures = joinpath(@__DIR__, "fixtures")
        return Dict{String, String}(
            "DISTSSHKIT_TEST" => "1",
            "DISTSSHKIT_TEST_SSH" => joinpath(fixtures, "fake_setup_ssh.jl"),
            "DISTSSHKIT_TEST_RSYNC" => joinpath(fixtures, "fake_setup_rsync.sh"),
            "DISTSSHKIT_TEST_STATE_ROOT" => abspath(string(state_dir)),
            "DISTSSHKIT_YES" => "1",
        )
    end
end
