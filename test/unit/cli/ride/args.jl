using Test

@testset "ride args" begin
    parse_ride_args = DistSSHRun.parse_ride_args

    let r = parse_ride_args(["--local-workers", "2", "job.jl", "--n", "4"])
        @test r.script_path == "job.jl"
        @test r.hosts == String[]
        @test r.cli_session.local_workers == 2
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
    let r = parse_ride_args(["--local-workers", "1", "2*host1", "--julia", "julia", "job.jl"])
        @test r.cli_session.local_workers == 1
        @test r.hosts == ["2*host1"]
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
        @test occursin("--unsafe-skip-env-digests", help)
        err = try
            parse_ride_args(["--allow-mismatch", "job.jl"])
            nothing
        catch e
            e
        end
        err isa ArgumentError || error("expected ArgumentError")
        @test occursin("DSSH-E001", err.msg)
        @test occursin("--allow-mismatch was removed", err.msg)
        @test occursin("--unsafe-skip-env-digests", err.msg)
        @test !occursin("--analyze", help)
        @test !occursin("--gb-per-worker", help)
        @test_throws ArgumentError parse_ride_args(["--gb-per-worker", "1.5", "job.jl"])
        @test occursin("--deploy-root", help)
        let r = parse_ride_args(["--deploy-root", "/tmp/App", "--local-workers", "1", "job.jl", "--n", "2"])
            @test r.deploy_root == "/tmp/App"
            @test r.script_args == ["--n", "2"]
        end
        let r = parse_ride_args(["--local-workers", "1", "job.jl", "--deploy-root", "/tmp/x"])
            @test r.deploy_root === nothing
            @test r.script_args == ["--deploy-root", "/tmp/x"]
        end
        @test_throws ArgumentError parse_ride_args(["--remote-path", "/tmp/App", "job.jl"])
        @test_throws ArgumentError parse_ride_args(["--remote-path=/tmp/App", "job.jl"])
        @test !occursin("#!/usr/bin/env julia", help)
    end
end
