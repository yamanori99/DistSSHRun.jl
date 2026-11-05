using Test

@testset "worker plan" begin
    @test DistSSHSize.rss_bytes_to_worker_gb(0) == DistSSHSize.WORKER_MEMORY_GB_FALLBACK
    one_gb = 1024^3
    @test DistSSHSize.rss_bytes_to_worker_gb(one_gb) == round(
        max(1.0 * DistSSHSize.WORKER_RSS_SAFETY_FACTOR, DistSSHSize.WORKER_MEMORY_GB_FLOOR),
        digits = 2,
    )
    plan = DistSSHSize.WorkerPlan(2, Dict("h" => 3, "z" => 0))
    toks = DistSSHSize.resolved_placement_tokens(plan)
    @test "parent:2" in toks
    @test "child:h:3" in toks
    @test !any(t -> occursin("z", t), toks)
    hosts = Tuple{String, Union{Int, Nothing}}[("h", nothing)]
    @test DistSSHSize.resolved_placement_tokens(1, hosts, 4) ==
        DistSSHSize.resolved_placement_tokens(DistSSHSize.WorkerPlan(1, Dict("h" => 4)))
    sample = DistSSHSize.WorkerMemorySample(0.5, 1.2)
    @test DistSSHSize.effective_worker_gb(sample) == 1.2
    @test DistSSHSize.per_worker_gb_dict(Dict("h" => sample))["h"] == 1.2
    @test parentmodule(DistSSHSize.WorkerPlan) === DistSSHSize
    @test parentmodule(DistSSHSize.size_worker_count) === DistSSHSize
    @test parentmodule(DistSSHSize.get_local_resources) === DistSSHSize
    @test parentmodule(DistSSHSize.compute_worker_plan) === DistSSHSize
    @test !isdefined(DistSSHBase, :WorkerPlan)
    @test !isdefined(DistSSHBase, :size_worker_count)
    @test !isdefined(DistSSHBase, :get_local_resources)
    @test DistSSHSize.size_worker_count(32.0, 2, 1.0; is_parent = true) == 1
    @test DistSSHSize.size_worker_count(32.0, nothing, 1.0; is_parent = true) ==
        max(0, floor(Int, (32.0 * DistSSHSize.DEFAULT_MEM_HEADROOM - DistSSHSize.DEFAULT_PARENT_GB) / 1.0))
    local_res = DistSSHSize.get_local_resources()
    @test local_res.total_gb > 0
    @test local_res.nproc > 0
    plan = DistSSHSize.compute_worker_plan(
        ["parent"], String[], Dict("parent" => 1.0),
    )
    @test plan.parent_workers == DistSSHSize.size_worker_count(
        local_res.total_gb, local_res.nproc, 1.0; is_parent = true,
    )
    @test isempty(plan.child_workers)
end
