using Test

@testset "plan args" begin
    parse_plan_args = DistSSHRun.parse_plan_args

    @testset "help and script" begin
        @test parse_plan_args(["--help"]).show_help
        @test parse_plan_args(["-h"]).show_help
        let r = parse_plan_args(["job.jl"])
            @test r.script_path == "job.jl"
            @test !r.show_help
            @test !r.show_version
        end
        let r = parse_plan_args(["--version"])
            @test r.show_version
            @test r.script_path === nothing
        end
        let r = parse_plan_args(["parent", "--gb-per-worker", "1.5", "job.jl"])
            @test r.script_path == "job.jl"
            @test r.tokens == ["parent"]
            @test r.gb_per_worker == 1.5
        end
        let r = parse_plan_args(["--probe", "warm.jl", "job.jl"])
            @test r.probe == "warm.jl"
            @test r.script_path == "job.jl"
        end
        @test_throws ArgumentError parse_plan_args(["a.jl", "b.jl"])
        @test_throws ArgumentError parse_plan_args(["job.jl", "extra"])
        for args in (["--nope", "job.jl"], ["--nope", "--help"], ["--help", "--nope"], ["-h", "--nope"])
            let err = try
                    parse_plan_args(args)
                    error("expected ArgumentError")
                catch e
                    e
                end
                @test err isa ArgumentError
                @test occursin("unknown plan option: --nope", err.msg)
                @test occursin("help plan", err.msg)
                @test !occursin("--help", err.msg)
            end
        end
        @test parse_plan_args(["--gb-per-worker", "1.5", "--help"]).show_help
        let err = try
                parse_plan_args(["--parent-gb", "--nope"])
                error("expected ArgumentError")
            catch e
                e
            end
            @test err isa ArgumentError
            @test !occursin("unknown plan option", err.msg)
        end
    end
end
