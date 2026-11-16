using Test
using DistSSHRun

@testset "topology and bind rules" begin
    @test DistSSHRun.resolved_topology("master_worker") == :master_worker
    @test DistSSHRun.topology_for_launch() == :master_worker
    plan = DistSSHRun.validate_host_launch_plan("h1", "127.0.0.1")
    @test plan.topology == :master_worker
    line = DistSSHRun.format_host_launch_plan_line(plan)
    @test occursin("bind=127.0.0.1", line)
    @test occursin("topology=master_worker", line)
    @test_throws ArgumentError DistSSHRun.validate_host_launch_plan(
        "h1",
        "127.0.0.1";
        tunnel = false
    )
    @test_throws ArgumentError DistSSHRun.validate_host_launch_plan(
        "h1",
        "0.0.0.0";
        unsafe_expose_port = false
    )
end
