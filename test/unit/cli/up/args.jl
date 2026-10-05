using Test

@testset "up args" begin
    parse_up_args = DistSSHRun.parse_up_args

    @test parse_up_args(["--help"]).show_help
    @test parse_up_args(["-h"]).show_help

    let r = parse_up_args(["add", "1.13", "child:host1", "child:host2"])
        @test r.verb == "add"
        @test r.channel == "1.13"
        @test r.hosts == ["host1", "host2"]
    end
    let r = parse_up_args(["default", "release", "parent", "child:host1"])
        @test r.verb == "default"
        @test r.channel == "release"
        @test r.hosts == ["parent", "host1"]
    end
    let r = parse_up_args(["update", "child:host1:4"])
        @test r.verb == "update"
        @test r.channel === nothing
        @test r.hosts == ["host1"]
    end
    let r = parse_up_args(["update", "1.13", "parent"])
        @test r.verb == "update"
        @test r.channel == "1.13"
        @test r.hosts == ["parent"]
    end
    let r = parse_up_args(["status", "parent"])
        @test r.verb == "status"
        @test r.channel === nothing
        @test r.hosts == ["parent"]
    end
    @test_throws ArgumentError parse_up_args(["child:host1"])
    @test_throws ArgumentError parse_up_args(["add", "parent"])
    @test_throws ArgumentError parse_up_args(["--juliaup", "child:host1"])
    @test_throws ArgumentError parse_up_args(["--nope"])

    txt = DistSSHRun.up_help_text()
    @test occursin("DistSSHKit up", txt)
    @test occursin("julia --project=. -m DistSSHKit up", txt)
    @test occursin("up add 1.13", txt)
    @test occursin("up default 1.13", txt)
    @test occursin("up update", txt)
    @test occursin("up status", txt)
    err = try
        parse_up_args(["child:host1"])
        ""
    catch e
        e isa ArgumentError ? e.msg : ""
    end
    @test occursin("up add 1.13", err)
end
