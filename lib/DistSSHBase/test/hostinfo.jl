using Test

@testset "hostinfo facts" begin
    localf = DistSSHBase.collect_host_facts("parent")
    @test localf.reachable
    @test localf.error === nothing
    @test localf.total_memory_bytes !== nothing
    @test localf.ncpu !== nothing
    @test localf.os !== nothing
    parsed = DistSSHBase._hostinfo_parse_probe("DISTSSHKIT_HOSTINFO\n17179869184\n4\nLinux\n")
    @test parsed !== nothing
    @test parsed.ncpu == 4
    @test parsed.total_memory_bytes == UInt64(17179869184)
    @test parsed.os == "Linux"
    @test DistSSHBase._hostinfo_parse_probe("nope") === nothing
    @test DistSSHBase._hostinfo_parse_u64("0") === nothing
    @test DistSSHBase._hostinfo_parse_ncpu("0") === nothing

    _with_tempdir() do state_dir
        env = merge(
            _fake_setup_remote_env(state_dir),
            Dict(
                "DISTSSHKIT_TEST_POOL_MEM" => "8589934592",
                "DISTSSHKIT_TEST_POOL_NCPU" => "8",
                "DISTSSHKIT_TEST_HOSTINFO_OS" => "Linux",
            ),
        )
        withenv(env...) do
            facts = DistSSHBase.collect_host_facts("host1")
            @test facts.reachable
            @test facts.ncpu == 8
            @test facts.total_memory_bytes == UInt64(8589934592)
            @test facts.os == "Linux"
            @test DistSSHBase.get_remote_nproc("host1") == 8
        end
        withenv(merge(env, Dict("DISTSSHKIT_TEST_SSH_FAIL" => "1"))...) do
            bad = DistSSHBase.collect_host_facts("host1")
            @test !bad.reachable
            @test bad.ncpu === nothing
            @test bad.total_memory_bytes === nothing
        end
    end
end
