using Test

function _hostinfo_fixture(;
        selector::String = "parent",
        identity::String = DistSSHRun.PARENT_HOST_NAME,
        reachable::Bool = true,
        error = nothing,
        total_memory_bytes = UInt64(25769803776),
        ncpu = 10,
        os = "Darwin",
        os_version = "27.2",
        os_pretty = "macOS",
        kernel_release = "27.2.0",
        arch = "arm64",
        cpu_model = "Apple M4",
        julia_exe = "/Users/example/.julia/juliaup/julia-1.13.3+0.aarch64.apple.darwin14/bin/julia",
        julia_version = "julia version 1.13.3",
    )
    return DistSSHRun.DistSSHBase.HostFacts(
        selector,
        identity,
        reachable,
        error,
        total_memory_bytes,
        ncpu,
        os,
        os_version,
        os_pretty,
        kernel_release,
        arch,
        cpu_model,
        julia_exe,
        julia_version,
    )
end

@testset "hostinfo" begin
    facts = DistSSHRun.DistSSHBase.collect_host_facts("parent")
    @test facts.reachable
    @test facts.identity == DistSSHRun.PARENT_HOST_NAME
    @test facts.arch !== nothing
    @test !occursin("0 GB", sprint(io -> DistSSHRun.print_hostinfo([facts]; io = io))) ||
        facts.total_memory_bytes !== nothing

    buf = IOBuffer()
    DistSSHRun.print_hostinfo([facts]; io = buf)
    let printed = String(take!(buf))
        @test occursin("Hostinfo:", printed)
        @test occursin("Status:", printed)
        @test occursin("ok", printed)
        @test occursin("parent", printed)
        @test occursin("Julia:", printed)
        @test occursin("OS:", printed)
        @test occursin("Kernel:", printed)
        @test occursin("CPU:", printed)
        @test occursin("Memory:", printed)
    end

    mac = _hostinfo_fixture()
    mac_out = sprint(io -> DistSSHRun.print_hostinfo([mac]; io = io))
    @test occursin("macOS 27.2", mac_out)
    @test occursin("Darwin 27.2.0", mac_out)
    @test occursin("arm64, 10 cores", mac_out)
    @test occursin("Apple M4", mac_out)
    @test occursin("Julia exe:", mac_out)
    @test !occursin("ok    Darwin", mac_out)

    linux = _hostinfo_fixture(;
        selector = "child:lab",
        identity = "lab",
        os = "Linux",
        os_version = "24.04",
        os_pretty = "Ubuntu 24.04.1 LTS",
        kernel_release = "6.8.0-40-generic",
        arch = "x86_64",
        cpu_model = "Intel(R) Test",
        julia_exe = "/usr/bin/julia",
        julia_version = "julia version 1.13.1",
        ncpu = 8,
        total_memory_bytes = UInt64(17179869184),
    )
    linux_out = sprint(io -> DistSSHRun.print_hostinfo([linux]; io = io))
    @test occursin("Ubuntu 24.04.1 LTS", linux_out)
    @test occursin("Linux 6.8.0-40-generic", linux_out)
    @test occursin("x86_64, 8 cores", linux_out)
    @test !occursin("24.04.1 LTS 24.04", linux_out)

    wsl = _hostinfo_fixture(;
        selector = "child:wsl",
        identity = "wsl",
        os = "Linux",
        os_version = "24.04",
        os_pretty = "Ubuntu 24.04.1 LTS",
        kernel_release = "6.8.0-microsoft-standard-WSL2",
        arch = "x86_64",
        cpu_model = nothing,
        julia_exe = nothing,
        julia_version = nothing,
    )
    wsl_out = sprint(io -> DistSSHRun.print_hostinfo([wsl]; io = io))
    @test occursin("(WSL)", wsl_out)
    @test occursin(r"Julia\s*:\s+-", wsl_out)
    @test occursin("Julia exe:", wsl_out)
    @test !occursin("CPU model:", wsl_out)

    missing_bits = _hostinfo_fixture(;
        os_version = nothing,
        os_pretty = nothing,
        kernel_release = nothing,
        arch = nothing,
        cpu_model = nothing,
        ncpu = nothing,
        total_memory_bytes = nothing,
        julia_exe = nothing,
        julia_version = nothing,
    )
    miss_out = sprint(io -> DistSSHRun.print_hostinfo([missing_bits]; io = io))
    @test occursin("Status:", miss_out)
    @test occursin("ok", miss_out)
    @test occursin("Memory:", miss_out)
    @test occursin("-", miss_out)
    @test !occursin("0 GB", miss_out)
    @test !occursin("0 cores", miss_out)
    @test !occursin("CPU model:", miss_out)

    failed = DistSSHRun.DistSSHBase.HostFacts(
        "ghost", "ghost", false, "connection refused",
        nothing, nothing, nothing, nothing, nothing,
        nothing, nothing, nothing, nothing, nothing,
    )
    failout = sprint(io -> DistSSHRun.print_hostinfo([failed]; io = io))
    @test occursin("fail", failout)
    @test occursin("connection refused", failout)
    @test occursin("Error:", failout)
    @test !occursin(" 0 cores", failout)
    @test !occursin("Memory:", failout)

    multi = sprint(io -> DistSSHRun.print_hostinfo([mac, linux, failed]; io = io))
    @test occursin("3 hosts", multi)
    @test occursin("(1 host failed)", multi)
    @test occursin("parent", multi)
    @test occursin("lab", multi)
    @test occursin("ghost", multi)

    long_exe = _hostinfo_fixture(;
        julia_exe = "/" * join(fill("very-long-julia-path-segment", 12), "/") * "/bin/julia",
    )
    narrow = IOContext(IOBuffer(), :displaysize => (24, 40))
    DistSSHRun.print_hostinfo([long_exe]; io = narrow)
    long_out = String(take!(narrow.io))
    @test occursin("Julia exe:", long_out)
    @test occursin("very-long-julia-path-segment", long_out)
    @test occursin("\n    /", long_out) || count(==('\n'), long_out) >= 8

    nontty = sprint(io -> DistSSHRun.print_hostinfo([mac]; io = io))
    @test occursin("Hostinfo:", nontty)
    @test occursin("Memory:", nontty)

    r = DistSSHRun.parse_hostinfo_args(["parent", "child:host1"])
    @test r.include_parent
    @test r.hosts == ["host1"]
    @test_throws ArgumentError DistSSHRun.parse_hostinfo_args(["--gb-per-worker", "1.5", "parent"])
    help = sprint(io -> DistSSHRun.show_hostinfo_usage(; io = io))
    @test occursin("hostinfo", help)
    @test occursin("versioninfo", help)
    @test occursin("print_hostinfo", help)
    @test !occursin("--gb-per-worker", help)

    _with_tempdir() do tmp
        write(joinpath(tmp, "Project.toml"), "name = \"HostinfoHost\"\n")
        mktemp() do out_path, out_io
            code = redirect_stdout(out_io) do
                redirect_stderr(devnull) do
                    DistSSHRun.run_hostinfo(["parent"])
                end
            end
            flush(out_io)
            out = read(out_path, String)
            @test code == 0
            @test occursin("parent", out)
            @test occursin("Hostinfo:", out)
            @test occursin("Status:", out)
        end
        mktemp() do out_path, out_io
            code = redirect_stdout(out_io) do
                redirect_stderr(devnull) do
                    DistSSHRun.run_hostinfo(["--quiet", "parent"])
                end
            end
            flush(out_io)
            out = read(out_path, String)
            @test code == 0
            @test occursin("Hostinfo:", out)
            @test occursin("parent", out)
            @test occursin("Status:", out)
        end
    end
end
