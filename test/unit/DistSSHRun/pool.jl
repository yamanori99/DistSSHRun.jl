using Test

@testset "pool" begin
    @testset "hostinfo probe parse" begin
        p = DistSSHRun.DistSSHBase._hostinfo_parse_probe("DISTSSHKIT_HOSTINFO\n17179869184\n4\nLinux\n")
        @test p !== nothing
        if p !== nothing
            @test p.ncpu == 4
            @test p.total_memory_bytes == UInt64(17179869184)
        end
    end

    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"PoolHost\"\n")
        empty = DistSSHRun.KitSession(project = proj, workers = String[])
        @test_throws ArgumentError DistSSHRun.pool!(empty)

        parent = DistSSHRun.KitSession(project = proj, workers = ["parent:1"])
        pool = DistSSHRun.pool!(parent)
        @test pool.ok
        @test length(pool.hosts) == 1
        @test pool.hosts[1].ok
        @test pool.hosts[1].host == DistSSHRun.PARENT_HOST_NAME
        @test pool.cores == pool.hosts[1].nproc
        @test !hasfield(typeof(pool), :slots)
        buf = IOBuffer()
        DistSSHRun.print_pool(pool; io = buf)
        txt = String(take!(buf))
        @test occursin("Pool:", txt)
        @test !occursin("slots", txt)
        @test occursin("cores", sprint(show, pool))
    end

    _with_tempdir() do proj
        write(joinpath(proj, "Project.toml"), "name = \"PoolHost\"\n")
        _with_tempdir() do state_dir
            env = merge(
                _fake_setup_remote_env(state_dir),
                Dict(
                    "DISTRIBUTED_PROJECT_ROOT" => proj,
                    "DISTRIBUTED_REMOTE_PROJECT_ROOT" => "/fake/remote/PoolHost",
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
                okp = DistSSHRun.pool!(sess)
                @test okp.ok
                @test length(okp.hosts) == 1
                @test okp.hosts[1].nproc == 8
                @test okp.cores == 8
                facts = DistSSHRun.DistSSHBase.collect_host_facts("host1")
                @test facts.ncpu == 8
                @test facts.os == "Linux"
            end
            fail_env = merge(env, Dict("DISTSSHKIT_TEST_SSH_FAIL" => "1"))
            withenv(fail_env...) do
                DistSSHRun.apply_kit_cli_session!(DistSSHRun.KitCliSession(quiet = true, yes = true))
                sess = DistSSHRun.KitSession(
                    project = proj,
                    workers = ["child:host1"],
                    remote = "/fake/remote/PoolHost",
                )
                bad = DistSSHRun.pool!(sess)
                @test !bad.ok
                @test length(bad.hosts) == 1
                @test !bad.hosts[1].ok
                @test bad.hosts[1].nproc === nothing
                @test bad.hosts[1].total_gb === nothing
                @test bad.cores === nothing
            end
        end
    end
end
