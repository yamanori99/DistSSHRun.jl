using Test

@testset "pool" begin
    @testset "parse probe" begin
        p = DistSSHRun._pool_parse_probe("DISTSSHKIT_POOL\n17179869184\n4\n")
        @test p !== nothing
        if p !== nothing
            @test p.nproc == 4
            @test p.total_gb ≈ 16.0 atol = 0.1
        end
        @test DistSSHRun._pool_parse_probe("nope") === nothing
        @test DistSSHRun._pool_parse_probe("DISTSSHKIT_POOL\n1\n") === nothing
    end

    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"PoolHost\"\n")
        empty = DistSSHRun.KitSession(project = proj, workers = String[])
        @test_throws ArgumentError DistSSHRun.pool!(empty)

        parent = DistSSHRun.KitSession(project = proj, workers = ["parent:1"])
        pool = DistSSHRun.pool!(parent; gb_per_worker = 2.0)
        @test pool.ok
        @test length(pool.hosts) == 1
        @test pool.hosts[1].ok
        @test pool.hosts[1].host == DistSSHRun.PARENT_HOST_NAME
        @test pool.cores == pool.hosts[1].nproc
        @test pool.slots == pool.hosts[1].slots
        wp = DistSSHRun.worker_plan_from_pool(pool)
        @test wp.parent_workers == pool.slots
        buf = IOBuffer()
        DistSSHRun.print_pool(pool; io = buf)
        @test occursin("Pool:", String(take!(buf)))
        @test occursin("cores", sprint(show, pool))
    end

    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"PoolHost\"\n")
        _with_tempdir() do state_dir
            env = merge(
                _fake_setup_remote_env(state_dir),
                Dict(
                    "DISTRIBUTED_PROJECT_ROOT" => proj,
                    "DISTSSHKIT_TEST_POOL_MEM" => "8589934592",
                    "DISTSSHKIT_TEST_POOL_NCPU" => "8",
                ),
            )
            withenv(env...) do
                DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession(quiet = true, yes = true))
                sess = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1"],
                    remote = "/fake/remote/PoolHost",
                )
                okp = DistSSHRun.pool!(sess; gb_per_worker = 1.5)
                @test okp.ok
                @test length(okp.hosts) == 1
                @test okp.hosts[1].nproc == 8
                @test okp.cores == 8
            end
            fail_env = merge(env, Dict("DISTSSHKIT_TEST_SSH_FAIL" => "1"))
            withenv(fail_env...) do
                DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession(quiet = true, yes = true))
                sess = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1"],
                    remote = "/fake/remote/PoolHost",
                )
                bad = DistSSHRun.pool!(sess; gb_per_worker = 1.5)
                @test !bad.ok
                @test length(bad.hosts) == 1
                @test !bad.hosts[1].ok
                @test bad.cores == 0
                @test bad.slots == 0
            end
        end
    end
end
