using Test

@testset "run transfer removal" begin
    for (api, val, needle) in (
            ("go!", :git_sync, "no longer transfers"),
            ("drive!", :ship_tree, "no longer transfers"),
            ("pipeline!", :git_sync, "no longer transfers"),
        )
        err = try
            if api == "go!"
                DistSSHRun.go!("job.jl", ["parent:1"]; sync = val, yes = true)
            elseif api == "drive!"
                DistSSHRun.drive!("job.jl", ["parent:1"]; sync = val, yes = true)
            else
                DistSSHRun.pipeline!(
                    DistSSHRun.PipelineConfig(;
                        driver = "job.jl",
                        workers = ["parent:1"],
                        sync = val,
                    ),
                )
            end
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(needle, err.msg)
        @test occursin("setup", lowercase(err.msg))
    end
    withenv("SYNC_MODE" => "git-sync") do
        err = try
            DistSSHRun.pipeline_config_from_env(; driver = "job.jl")
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("SYNC_MODE", err.msg)
    end
end
