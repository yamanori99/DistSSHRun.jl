using Test
using DistSSHBase

@testset "run_ssh auth timeout" begin
    withenv(
        "DISTSSH_WAIT_SSH_AUTH" => "0.15",
        "DISTSSH_TEST" => "1",
        "DISTSSH_TEST_SSH" => abspath(
            joinpath(@__DIR__, "..", "fixtures", "fake_ssh_impl.jl"),
        ),
        "DISTSSH_TEST_SSH_HANG" => "1",
        "DISTSSH_TEST_STATE_ROOT" => mktempdir(),
    ) do
        @test_throws ArgumentError DistSSHBase.run_ssh(
            pipeline(
                DistSSHBase._host_sync_remote_shell_cmd("host1", "true");
                stdout = devnull,
                stderr = devnull,
            );
            wait = true,
        )
    end
end

@testset "ssh_phase_argv" begin
    withenv("DISTRIBUTED_SSH_OPTS" => nothing) do
        vec = DistSSHBase.ssh_phase_argv()
        @test "BatchMode=yes" in vec
        @test occursin("ConnectTimeout=", join(vec, " "))
    end
end