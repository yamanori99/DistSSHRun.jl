using Test
using Distributed
using Random

@testset "plan ranks and worker_pmap item seeds" begin
    @testset "reserve_worker_ranks keeps holes out of provenance" begin
        DistSSHRun.reset_worker_seeds!()
        DistSSHRun.reset_launch_rank_plan!(1:5)
        withenv("DISTSSH_JOB_SEED" => "7") do
            DistSSHRun.job_seed()
            skipped = DistSSHRun.reserve_worker_ranks!(2)
            @test skipped == [1, 2]
            seeds = DistSSHRun._seed_provenance()
            @test seeds === nothing || !haskey(seeds, "workers")
            next = DistSSHRun.reserve_worker_ranks!(1)
            @test next == [3]
            DistSSHRun.register_launch_rank!(42, 3)
            env = Dict(DistSSHRun.worker_env_pairs("/tmp/job"; rank = 3))
            @test env["DISTSSH_WORKER_RANK"] == "3"
            @test parse(UInt64, env["DISTSSH_WORKER_SEED"]) == DistSSHRun.worker_seed(7, 3)
        end
    end

    @testset "worker_pmap item RNG is independent of workers and batch_size" begin
        job_val = UInt64(100)
        call = 1
        n = 6
        ref = [
            rand(Random.Xoshiro(DistSSHRun.job_item_seed(job_val, call, i)), UInt64) for i in 1:n
        ]
        DistSSHRun.reset_worker_seeds!()
        withenv("DISTSSH_JOB_SEED" => string(job_val)) do
            DistSSHRun.job_seed()
            solo = DistSSHRun.worker_pmap(x -> rand(UInt64), 1:n)
            @test solo == ref
        end

        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        proj = if isdefined(@__MODULE__, :TEST_PROJECT)
            String(TEST_PROJECT)
        else
            String(something(Base.active_project(), pkgdir(DistSSHRun)))
        end
        multi_code = """
        using Random, Distributed, DistSSHRun
        const job_val = UInt64($(job_val))
        const n = $n
        const call = $call
        ref = [rand(Random.Xoshiro(DistSSHRun.job_item_seed(job_val, call, i)), UInt64) for i in 1:n]
        before = Set(workers())
        try
            addprocs(2; exeflags=`--startup-file=no --history-file=no --project=$proj`)
            @everywhere using DistSSHRun
            ok = true
            for batch in (1, 2, n)
                DistSSHRun.reset_worker_seeds!()
                withenv("DISTSSH_JOB_SEED" => string(job_val)) do
                    DistSSHRun.job_seed()
                    got = DistSSHRun.worker_pmap(x -> rand(UInt64), 1:n; batch_size = batch)
                    ok &= got == ref
                end
            end
            print(ok ? "ok" : "fail")
        finally
            extra = collect(setdiff(workers(), before))
            isempty(extra) || rmprocs(extra; waitfor = 30)
        end
        """
        @test strip(String(read(`$julia --startup-file=no --history-file=no --project=$proj -e $multi_code`))) == "ok"

        DistSSHRun.reset_worker_seeds!()
        withenv("DISTSSH_JOB_SEED" => string(job_val)) do
            DistSSHRun.job_seed()
            _ = DistSSHRun.worker_pmap(identity, [1])
            DistSSHRun.reset_worker_seeds!()
            withenv("DISTSSH_JOB_SEED" => string(job_val)) do
                DistSSHRun.job_seed()
                again = DistSSHRun.worker_pmap(x -> rand(UInt64), 1:n)
                @test again == ref
            end
        end
    end
end