using Test

@testset "hostinfo facts" begin
    localf = DistSSHBase.collect_host_facts("parent")
    @test localf.reachable
    @test localf.error === nothing
    @test localf.total_memory_bytes !== nothing
    @test localf.ncpu !== nothing
    @test localf.os !== nothing
    parsed = DistSSHBase._hostinfo_parse_probe("DISTSSHKIT_HOSTINFO\nmem=17179869184\nncpu=4\nos=Linux\n")
    @test parsed !== nothing
    if parsed !== nothing
        @test parsed.ncpu == 4
        @test parsed.total_memory_bytes == UInt64(17179869184)
        @test parsed.os == "Linux"
    end
    @test DistSSHBase._hostinfo_parse_probe("nope") === nothing
    @test DistSSHBase._hostinfo_parse_u64("0") === nothing
    @test DistSSHBase._hostinfo_parse_ncpu("0") === nothing

    # Positional shift: missing RAM leaves CPU then OS. Must not treat ncpu as RAM.
    shifted = DistSSHBase._hostinfo_parse_probe("DISTSSHKIT_HOSTINFO\n4\nLinux\n")
    @test shifted !== nothing
    if shifted !== nothing
        @test shifted.total_memory_bytes === nothing
        @test shifted.ncpu === nothing
        @test shifted.os === nothing
    end
    empty_mem = DistSSHBase._hostinfo_parse_probe("DISTSSHKIT_HOSTINFO\nmem=\nncpu=4\nos=Linux\n")
    @test empty_mem !== nothing
    if empty_mem !== nothing
        @test empty_mem.total_memory_bytes === nothing
        @test empty_mem.ncpu == 4
        @test empty_mem.os == "Linux"
    end
    empty_cpu = DistSSHBase._hostinfo_parse_probe("DISTSSHKIT_HOSTINFO\nmem=8589934592\nncpu=\nos=Darwin\n")
    @test empty_cpu !== nothing
    if empty_cpu !== nothing
        @test empty_cpu.total_memory_bytes == UInt64(8589934592)
        @test empty_cpu.ncpu === nothing
        @test empty_cpu.os == "Darwin"
    end
    empty_os = DistSSHBase._hostinfo_parse_probe("DISTSSHKIT_HOSTINFO\nmem=8589934592\nncpu=2\nos=\n")
    @test empty_os !== nothing
    if empty_os !== nothing
        @test empty_os.ncpu == 2
        @test empty_os.os === nothing
    end
    @test DistSSHBase._hostinfo_parse_u64("not-a-number") === nothing
    @test DistSSHBase._hostinfo_parse_ncpu("Linux") === nothing
    @test DistSSHBase._hostinfo_parse_u64("1.6777216e10") == UInt64(16777216000)
    @test DistSSHBase._hostinfo_parse_u64("1.6777216E10") == UInt64(16777216000)

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
            @test bad.os === nothing
        end
        withenv(merge(env, Dict("DISTSSHKIT_TEST_POOL_MEM" => ""))...) do
            nomem = DistSSHBase.collect_host_facts("host1")
            @test nomem.reachable
            @test nomem.total_memory_bytes === nothing
            @test nomem.ncpu == 8
            @test nomem.os == "Linux"
            @test DistSSHBase.get_remote_total_gb("host1") === nothing
            @test DistSSHBase.get_remote_nproc("host1") == 8
        end
        withenv(merge(env, Dict("DISTSSHKIT_TEST_HOSTINFO_OMIT_MEM" => "1"))...) do
            omit = DistSSHBase.collect_host_facts("host1")
            @test omit.reachable
            @test omit.total_memory_bytes === nothing
            @test omit.ncpu == 8
        end
    end
end
