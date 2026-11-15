# Shared by DistSSHBase's own tests.
include(joinpath(@__DIR__, "shared_tempdir.jl"))

if !isdefined(Main, :_run_subprocess)
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
            "DISTSSH_TEST_SNAP_GIT_YES" => "1",
        )
    end
end
