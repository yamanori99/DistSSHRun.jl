using Test

@testset "hostinfo facts" begin
    localf = DistSSHBase.collect_host_facts("parent")
    @test localf.reachable
    @test localf.error === nothing
    @test localf.total_memory_bytes !== nothing
    @test localf.ncpu !== nothing
    @test localf.os !== nothing
    @test localf.arch !== nothing
    @test localf.kernel_release !== nothing
    parsed = DistSSHBase._hostinfo_parse_probe(
        """
        DISTSSH_HOSTINFO
        mem=17179869184
        ncpu=4
        os=Linux
        kernel=6.8.0-40-generic
        arch=x86_64
        os_version=24.04
        os_pretty=Ubuntu 24.04.1 LTS
        cpu_model=Test CPU
        """,
    )
    @test parsed !== nothing
    if parsed !== nothing
        @test parsed.ncpu == 4
        @test parsed.total_memory_bytes == UInt64(17179869184)
        @test parsed.os == "Linux"
        @test parsed.kernel_release == "6.8.0-40-generic"
        @test parsed.arch == "x86_64"
        @test parsed.os_version == "24.04"
        @test parsed.os_pretty == "Ubuntu 24.04.1 LTS"
        @test parsed.cpu_model == "Test CPU"
    end
    @test DistSSHBase._hostinfo_parse_probe("nope") === nothing
    @test DistSSHBase._hostinfo_parse_u64("0") === nothing
    @test DistSSHBase._hostinfo_parse_ncpu("0") === nothing

    # Positional shift: missing RAM leaves CPU then OS. Must not treat ncpu as RAM.
    shifted = DistSSHBase._hostinfo_parse_probe("DISTSSH_HOSTINFO\n4\nLinux\n")
    @test shifted !== nothing
    if shifted !== nothing
        @test shifted.total_memory_bytes === nothing
        @test shifted.ncpu === nothing
        @test shifted.os === nothing
        @test shifted.arch === nothing
        @test shifted.kernel_release === nothing
        @test shifted.os_version === nothing
        @test shifted.os_pretty === nothing
        @test shifted.cpu_model === nothing
    end
    empty_mem = DistSSHBase._hostinfo_parse_probe(
        "DISTSSH_HOSTINFO\nmem=\nncpu=4\nos=Linux\nkernel=1\narch=x86_64\n",
    )
    @test empty_mem !== nothing
    if empty_mem !== nothing
        @test empty_mem.total_memory_bytes === nothing
        @test empty_mem.ncpu == 4
        @test empty_mem.os == "Linux"
        @test empty_mem.arch == "x86_64"
    end
    empty_cpu = DistSSHBase._hostinfo_parse_probe(
        "DISTSSH_HOSTINFO\nmem=8589934592\nncpu=\nos=Darwin\narch=arm64\nos_version=27.2\nos_pretty=macOS\n",
    )
    @test empty_cpu !== nothing
    if empty_cpu !== nothing
        @test empty_cpu.total_memory_bytes == UInt64(8589934592)
        @test empty_cpu.ncpu === nothing
        @test empty_cpu.os == "Darwin"
        @test empty_cpu.os_version == "27.2"
        @test empty_cpu.os_pretty == "macOS"
        @test empty_cpu.arch == "arm64"
    end
    empty_os = DistSSHBase._hostinfo_parse_probe(
        "DISTSSH_HOSTINFO\nmem=8589934592\nncpu=2\nos=\narch=x86_64\n",
    )
    @test empty_os !== nothing
    if empty_os !== nothing
        @test empty_os.ncpu == 2
        @test empty_os.os === nothing
        @test empty_os.arch == "x86_64"
    end
    # Partial labels must not shift later keys.
    partial = DistSSHBase._hostinfo_parse_probe(
        """
        DISTSSH_HOSTINFO
        mem=8589934592
        ncpu=2
        os=Linux
        arch=x86_64
        """,
    )
    @test partial !== nothing
    if partial !== nothing
        @test partial.kernel_release === nothing
        @test partial.os_version === nothing
        @test partial.os_pretty === nothing
        @test partial.cpu_model === nothing
        @test partial.arch == "x86_64"
    end
    @test DistSSHBase._hostinfo_parse_u64("not-a-number") === nothing
    @test DistSSHBase._hostinfo_parse_ncpu("Linux") === nothing
    @test DistSSHBase._hostinfo_parse_u64("1.6777216e10") == UInt64(16777216000)
    @test DistSSHBase._hostinfo_parse_u64("1.6777216E10") == UInt64(16777216000)

    _with_tempdir() do state_dir
        env = merge(
            _fake_setup_remote_env(state_dir),
            Dict(
                "DISTSSH_TEST_POOL_MEM" => "8589934592",
                "DISTSSH_TEST_POOL_NCPU" => "8",
                "DISTSSH_TEST_HOSTINFO_OS" => "Linux",
                "DISTSSH_TEST_HOSTINFO_KERNEL" => "6.8.0-microsoft-standard-WSL2",
                "DISTSSH_TEST_HOSTINFO_ARCH" => "x86_64",
                "DISTSSH_TEST_HOSTINFO_OS_VERSION" => "24.04",
                "DISTSSH_TEST_HOSTINFO_OS_PRETTY" => "Ubuntu 24.04.1 LTS",
                "DISTSSH_TEST_HOSTINFO_CPU_MODEL" => "Intel(R) Test",
            ),
        )
        withenv(env...) do
            facts = DistSSHBase.collect_host_facts("host1")
            @test facts.reachable
            @test facts.ncpu == 8
            @test facts.total_memory_bytes == UInt64(8589934592)
            @test facts.os == "Linux"
            @test facts.kernel_release == "6.8.0-microsoft-standard-WSL2"
            @test facts.arch == "x86_64"
            @test facts.os_version == "24.04"
            @test facts.os_pretty == "Ubuntu 24.04.1 LTS"
            @test facts.cpu_model == "Intel(R) Test"
            @test DistSSHBase.get_remote_nproc("host1") == 8
        end
        withenv(merge(env, Dict("DISTSSH_TEST_SSH_FAIL" => "1"))...) do
            bad = DistSSHBase.collect_host_facts("host1")
            @test !bad.reachable
            @test bad.ncpu === nothing
            @test bad.total_memory_bytes === nothing
            @test bad.os === nothing
            @test bad.arch === nothing
            @test bad.kernel_release === nothing
            @test bad.os_version === nothing
            @test bad.os_pretty === nothing
            @test bad.cpu_model === nothing
        end
        withenv(merge(env, Dict("DISTSSH_TEST_POOL_MEM" => ""))...) do
            nomem = DistSSHBase.collect_host_facts("host1")
            @test nomem.reachable
            @test nomem.total_memory_bytes === nothing
            @test nomem.ncpu == 8
            @test nomem.os == "Linux"
            @test DistSSHBase.get_remote_total_gb("host1") === nothing
            @test DistSSHBase.get_remote_nproc("host1") == 8
        end
        withenv(merge(env, Dict("DISTSSH_TEST_HOSTINFO_OMIT_MEM" => "1"))...) do
            omit = DistSSHBase.collect_host_facts("host1")
            @test omit.reachable
            @test omit.total_memory_bytes === nothing
            @test omit.ncpu == 8
            @test omit.arch == "x86_64"
        end
        withenv(
            merge(
                env,
                Dict(
                    "DISTSSH_TEST_HOSTINFO_OMIT_ARCH" => "1",
                    "DISTSSH_TEST_HOSTINFO_OMIT_OS_VERSION" => "1",
                    "DISTSSH_TEST_HOSTINFO_OMIT_OS_PRETTY" => "1",
                    "DISTSSH_TEST_HOSTINFO_OMIT_CPU_MODEL" => "1",
                    "DISTSSH_TEST_HOSTINFO_OMIT_KERNEL" => "1",
                ),
            )...,
        ) do
            sparse = DistSSHBase.collect_host_facts("host1")
            @test sparse.reachable
            @test sparse.os == "Linux"
            @test sparse.arch === nothing
            @test sparse.kernel_release === nothing
            @test sparse.os_version === nothing
            @test sparse.os_pretty === nothing
            @test sparse.cpu_model === nothing
        end
        darwin_env = merge(
            env,
            Dict(
                "DISTSSH_TEST_HOSTINFO_OS" => "Darwin",
                "DISTSSH_TEST_HOSTINFO_KERNEL" => "27.2.0",
                "DISTSSH_TEST_HOSTINFO_ARCH" => "arm64",
                "DISTSSH_TEST_HOSTINFO_OS_VERSION" => "27.2",
                "DISTSSH_TEST_HOSTINFO_OS_PRETTY" => "macOS",
                "DISTSSH_TEST_HOSTINFO_CPU_MODEL" => "Apple M4",
            ),
        )
        withenv(darwin_env...) do
            mac = DistSSHBase.collect_host_facts("host1")
            @test mac.reachable
            @test mac.os == "Darwin"
            @test mac.os_version == "27.2"
            @test mac.os_pretty == "macOS"
            @test mac.kernel_release == "27.2.0"
            @test mac.arch == "arm64"
            @test mac.cpu_model == "Apple M4"
        end
    end
end
