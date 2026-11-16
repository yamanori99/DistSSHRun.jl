using Test

@testset "WorkerPlan" begin
    plan = DistSSHRun.WorkerPlan(2, Dict("h" => 3, "z" => 0))
    toks = DistSSHRun.resolved_placement_tokens(plan)
    @test !any(t -> startswith(t, "parent"), toks)
    @test "3*h" in toks
    @test !any(occursin(":z:", t) || endswith(t, ":z") for t in toks)
    hosts = [("h", nothing)]
    @test DistSSHRun.resolved_placement_tokens(1, hosts, 4) ==
        DistSSHRun.resolved_placement_tokens(DistSSHRun.WorkerPlan(1, Dict("h" => 4)))
    @test parentmodule(DistSSHRun.WorkerPlan) === DistSSHRun
    @test DistSSHRun.worker_plan_from_tokens(["3*h"]; local_workers = 2).parent_workers == 2
    let plan = DistSSHRun.worker_plan_from_tokens(["3*h"])
        @test plan.parent_workers == 0
        @test plan.child_workers["h"] == 3
    end
end
