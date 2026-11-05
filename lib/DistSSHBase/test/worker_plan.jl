using Test

@testset "worker plan" begin
    @test DistSSHBase.rss_bytes_to_worker_gb(0) == DistSSHBase.WORKER_MEMORY_GB_FALLBACK
    one_gb = 1024^3
    @test DistSSHBase.rss_bytes_to_worker_gb(one_gb) == round(
        max(1.0 * DistSSHBase.WORKER_RSS_SAFETY_FACTOR, DistSSHBase.WORKER_MEMORY_GB_FLOOR),
        digits = 2,
    )
    plan = DistSSHBase.WorkerPlan(2, Dict("h" => 3, "z" => 0))
    toks = DistSSHBase.resolved_placement_tokens(plan)
    @test "parent:2" in toks
    @test "child:h:3" in toks
    @test !any(t -> occursin("z", t), toks)
    hosts = Tuple{String, Union{Int, Nothing}}[("h", nothing)]
    @test DistSSHBase.resolved_placement_tokens(1, hosts, 4) ==
        DistSSHBase.resolved_placement_tokens(DistSSHBase.WorkerPlan(1, Dict("h" => 4)))
    sample = DistSSHBase.WorkerMemorySample(0.5, 1.2)
    @test DistSSHBase.effective_worker_gb(sample) == 1.2
    @test DistSSHBase.per_worker_gb_dict(Dict("h" => sample))["h"] == 1.2
    @test parentmodule(DistSSHBase.WorkerPlan) === DistSSHBase
    @test DistSSHBase.size_worker_count(32.0, 2, 1.0; is_parent = true) == 1
    @test DistSSHBase.size_worker_count(32.0, nothing, 1.0; is_parent = true) ==
        max(0, floor(Int, (32.0 * DistSSHBase.DEFAULT_MEM_HEADROOM - DistSSHBase.DEFAULT_PARENT_GB) / 1.0))
    local_res = DistSSHBase.get_local_resources()
    @test local_res.total_gb > 0
    @test local_res.nproc > 0
end
