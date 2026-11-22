# Shared by DistSSHBase's own tests.
include(joinpath(@__DIR__, "shared_tempdir.jl"))

if !isdefined(@__MODULE__, :_run_subprocess)
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

function _distssh_base_for_tests()
    m = @__MODULE__
    isdefined(m, :DistSSHBase) && return getfield(m, :DistSSHBase)
    isdefined(m, :DistSSHRun) && return getfield(getfield(m, :DistSSHRun), :DistSSHBase)
    return getfield(getfield(Main, :DistSSHRun), :DistSSHBase)
end

function _install_injected_ssh!()
    BaseMod = _distssh_base_for_tests()
    BaseMod._injected_ssh[] = BaseMod.InjectedSshTransport(
        () -> strip(get(ENV, "DISTSSH_TEST", "")) == "1",
        function (host, remote; forward_stdin = false)
            _ = forward_stdin
            strip(get(ENV, "DISTSSH_TEST", "")) == "1" || return nothing
            custom = strip(get(ENV, "DISTSSH_TEST_SSH", ""))
            isempty(custom) && return nothing
            base = Cmd(
                vcat(BaseMod._test_double_julia_argv(custom), [String(host), String(remote)]),
            )
            return setenv(base, BaseMod._fake_double_child_julia_env())
        end,
        () -> strip(get(ENV, "DISTSSH_TEST_POSIX_SHELL", "1")) == "0",
        function ()
            strip(get(ENV, "DISTSSH_TEST", "")) == "1" || return nothing
            s = strip(get(ENV, "DISTSSH_TEST_SSH", ""))
            return isempty(s) ? nothing : abspath(s)
        end,
        function ()
            strip(get(ENV, "DISTSSH_TEST", "")) == "1" || return nothing
            s = strip(get(ENV, "DISTSSH_TEST_LOCAL_JULIAUP", ""))
            return isempty(s) ? nothing : s
        end,
        function ()
            strip(get(ENV, "DISTSSH_TEST", "")) == "1" || return nothing
            s = strip(get(ENV, "DISTSSH_TEST_JULIA_WHICH", ""))
            return isempty(s) ? nothing : s
        end,
    )
    return nothing
end

_install_injected_ssh!()
