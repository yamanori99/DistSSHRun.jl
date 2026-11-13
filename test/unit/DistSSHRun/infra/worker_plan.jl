using Test

@testset "WorkerPlan" begin
    plan = DistSSHRun.WorkerPlan(2, Dict("h" => 3, "z" => 0))
    toks = DistSSHRun.resolved_placement_tokens(plan)
    @test "parent:2" in toks
    @test "child:h:3" in toks
    @test !any(occursin(":z:", t) || endswith(t, ":z") for t in toks)
    hosts = [("h", nothing)]
    @test DistSSHRun.resolved_placement_tokens(1, hosts, 4) ==
        DistSSHRun.resolved_placement_tokens(DistSSHRun.WorkerPlan(1, Dict("h" => 4)))
    @test parentmodule(DistSSHRun.WorkerPlan) === DistSSHRun
    @test DistSSHRun.worker_plan_from_tokens(["parent:2", "child:h:3"]).parent_workers == 2
    @test_throws ArgumentError DistSSHRun.worker_plan_from_tokens(["parent"])
end
