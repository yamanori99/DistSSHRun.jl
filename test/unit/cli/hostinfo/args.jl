using Test

@testset "hostinfo args" begin
    parse_hostinfo_args = DistSSHRun.parse_hostinfo_args
    let r = parse_hostinfo_args(["parent", "child:host1"])
        @test r.include_parent
        @test r.hosts == ["host1"]
        @test r.julia === nothing
    end
    @test_throws ArgumentError parse_hostinfo_args(["--probe", "warmup.jl"])
    @test DistSSHRun.parse_hostinfo_args(["--help"]).show_help
    help = sprint(io -> DistSSHRun.show_hostinfo_usage(; io = io))
    @test occursin("DistSSHKit hostinfo", help)
    @test !occursin("--gb-per-worker", help)
end
