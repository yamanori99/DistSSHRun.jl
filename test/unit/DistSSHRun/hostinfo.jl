using Test

@testset "hostinfo" begin
    facts = DistSSHRun.DistSSHBase.collect_host_facts("parent")
    @test facts.reachable
    @test facts.identity == DistSSHRun.PARENT_HOST_NAME
    @test facts.arch !== nothing

    # Run reexports Base.print_hostinfo for the kit public surface.
    buf = IOBuffer()
    DistSSHRun.print_hostinfo([facts]; io = buf)
    let printed = String(take!(buf))
        @test occursin("Hostinfo:", printed)
        @test occursin("Status:", printed)
        @test occursin("parent", printed)
    end
    @test DistSSHRun.print_hostinfo === DistSSHRun.DistSSHBase.print_hostinfo

    failed = DistSSHRun.DistSSHBase.HostFacts(
        "ghost", "ghost", false, "connection refused",
        nothing, nothing, nothing, nothing, nothing,
        nothing, nothing, nothing, nothing, nothing,
    )
    failout = sprint(io -> DistSSHRun.print_hostinfo([failed]; io = io))
    @test occursin("fail", failout)
    @test occursin("connection refused", failout)

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
