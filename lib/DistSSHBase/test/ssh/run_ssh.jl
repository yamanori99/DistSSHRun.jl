using Test
using DistSSHBase

@testset "posix probe auth timeout" begin
    withenv(
        "DISTSSH_WAIT_SSH_AUTH" => "0.15",
        "DISTSSH_TEST" => "1",
        "DISTSSH_TEST_SSH" => abspath(
            joinpath(@__DIR__, "..", "fixtures", "fake_ssh_impl.jl"),
        ),
        "DISTSSH_TEST_SSH_HANG" => "1",
        "DISTSSH_TEST_STATE_ROOT" => mktempdir(),
    ) do
        DistSSHBase._clear_remote_posix_shell_cache!()
        @test_throws ArgumentError DistSSHBase._ensure_posix_login_shell!("host1")
    end
end

@testset "run_ssh stdio and status" begin
    out = IOBuffer()
    DistSSHBase.run_ssh(pipeline(`echo run_ssh_stdio_ok`; stdout = out))
    @test occursin("run_ssh_stdio_ok", String(take!(out)))

    captured = mktemp() do path, io
        redirect_stdout(io) do
            DistSSHBase.run_ssh(`echo run_ssh_parent_stdio`)
        end
        flush(io)
        return read(path, String)
    end
    @test occursin("run_ssh_parent_stdio", captured)

    @test_throws Base.ProcessFailedException DistSSHBase.run_ssh(`sh -c 'exit 3'`)

    withenv("DISTSSH_WAIT_SSH_AUTH" => "0.15") do
        t0 = time()
        DistSSHBase.run_ssh(`sleep 0.6`)
        @test time() - t0 >= 0.5
    end
end

@testset "ssh_phase_argv" begin
    withenv("DISTRIBUTED_SSH_OPTS" => nothing) do
        vec = DistSSHBase.ssh_phase_argv()
        @test "BatchMode=yes" in vec
        @test occursin("ConnectTimeout=", join(vec, " "))
    end
    withenv("DISTRIBUTED_SSH_OPTS" => "-p 2200 -o Port=8888") do
        vec = DistSSHBase.ssh_phase_argv(; explicit_port = 2222)
        @test !("-p" in vec)
        @test !("2200" in vec)
        @test !("8888" in vec)
    end
end

function _cmd_env_lookup(cmd::Cmd, key::AbstractString)
    env = cmd.env
    if env !== nothing
        prefix = string(key, "=")
        for entry in env
            startswith(entry, prefix) || continue
            return split(entry, '=', limit = 2)[2]
        end
    end
    return get(ENV, key, nothing)
end

@testset "ssh and scp noninteractive env" begin
    want = DistSSHBase.ssh_noninteractive_env()
    for builder in (DistSSHBase._ssh_cmd, DistSSHBase._scp_cmd)
        withenv("SSH_AUTH_SOCK" => "/tmp/distssh-test-sock") do
            cmd = builder(String["x"])
            for (k, v) in want
                @test _cmd_env_lookup(cmd, k) == v
            end
            @test _cmd_env_lookup(cmd, "SSH_AUTH_SOCK") == "/tmp/distssh-test-sock"
        end
    end
end
