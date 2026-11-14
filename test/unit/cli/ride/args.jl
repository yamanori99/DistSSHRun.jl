using Test

@testset "ride args" begin
    parse_ride_args = DistSSHRun.parse_ride_args

    let r = parse_ride_args(["parent:2", "job.jl", "--n", "4"])
        @test r.script_path == "job.jl"
        @test r.hosts == ["parent:2"]
        @test r.script_args == ["--n", "4"]
        @test !r.spi_check
        @test !r.help
    end
    let r = parse_ride_args(["--spi-check", "job.jl"])
        @test r.spi_check
    end
    let r = parse_ride_args(["--no-spi-check", "job.jl"])
        @test !r.spi_check
    end
    let r = parse_ride_args(["parent:1", "child:host1:2", "--julia", "julia", "job.jl"])
        @test r.hosts == ["parent:1", "child:host1:2"]
        @test r.julia == "julia"
        @test r.script_path == "job.jl"
    end
    @test_throws ArgumentError parse_ride_args(["--analyze", "job.jl"])
    let path = tempname()
        @test parse_ride_args(["--help"]).help
        open(path, "w") do io
            DistSSHRun.show_ride_usage(; io = io)
        end
        help = read(path, String)
        rm(path; force = true)
        @test occursin("DistSSHKit ride", help)
        @test occursin("-m DistSSHKit", help)
        @test occursin("child:", help)
        @test occursin("--unsafe-heterogeneous", help)
        err = try
            parse_ride_args(["--allow-mismatch", "job.jl"])
            nothing
        catch e
            e
        end
        err isa ArgumentError || error("expected ArgumentError")
        @test occursin(
            "removed; use --unsafe-heterogeneous (Julia/DistSSH* can no longer be waived)",
            err.msg,
        )
        @test !occursin("--analyze", help)
        @test !occursin("--gb-per-worker", help)
        @test_throws ArgumentError parse_ride_args(["--gb-per-worker", "1.5", "job.jl"])
        @test occursin("--deploy-root", help)
        let r = parse_ride_args(["--deploy-root", "/tmp/App", "parent:1", "job.jl", "--n", "2"])
            @test r.deploy_root == "/tmp/App"
            @test r.script_args == ["--n", "2"]
        end
        let r = parse_ride_args(["parent:1", "job.jl", "--deploy-root", "/tmp/x"])
            @test r.deploy_root === nothing
            @test r.script_args == ["--deploy-root", "/tmp/x"]
        end
        @test_throws ArgumentError parse_ride_args(["--remote-path", "/tmp/App", "job.jl"])
        @test_throws ArgumentError parse_ride_args(["--remote-path=/tmp/App", "job.jl"])
        @test !occursin("#!/usr/bin/env julia", help)
    end
end
