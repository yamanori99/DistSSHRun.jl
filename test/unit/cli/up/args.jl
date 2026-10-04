using Test

@testset "up args" begin
    parse_up_args = DistSSHRun.parse_up_args

    @test parse_up_args(["--help"]).show_help
    @test parse_up_args(["-h"]).show_help

    let r = parse_up_args(["child:host1", "child:host2"])
        @test r.update == false
        @test r.hosts == ["host1", "host2"]
    end
    let r = parse_up_args(["parent", "child:host1"])
        @test r.update == false
        @test r.hosts == ["parent", "host1"]
    end
    let r = parse_up_args(["child:host1:4"])
        @test r.hosts == ["host1"]
    end
    let r = parse_up_args(["update", "child:host1"])
        @test r.update
        @test r.hosts == ["host1"]
    end
    let r = parse_up_args(["update", "parent"])
        @test r.update
        @test r.hosts == ["parent"]
    end
    @test_throws ArgumentError parse_up_args(["child:host1", "update"])
    @test_throws ArgumentError parse_up_args(["--juliaup", "child:host1"])
    @test_throws ArgumentError parse_up_args(["--nope"])

    txt = DistSSHRun.up_help_text()
    @test occursin("up update", txt)
    @test occursin("parent", txt)
    @test occursin("child:host1", txt)
end
