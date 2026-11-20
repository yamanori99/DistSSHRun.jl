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
end
