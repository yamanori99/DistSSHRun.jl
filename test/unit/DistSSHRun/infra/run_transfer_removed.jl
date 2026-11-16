using Test

@testset "run transfer removal" begin
    for (api, val, needle) in (
            ("go!", :git_sync, "no longer transfers"),
            ("drive!", :ship_tree, "no longer transfers"))
        err = try
            if api == "go!"
                DistSSHRun.go!("job.jl", String[]; head_slots = 1, sync = val)
            else
                DistSSHRun.drive!("job.jl", String[]; head_workers = 1, sync = val)
            end
            error("expected ArgumentError")
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(needle, err.msg)
        @test occursin("setup", lowercase(err.msg))
    end
    @test_throws MethodError DistSSHRun.PipelineConfig(;
        driver = "job.jl",
        workers = String[], head_workers = 1,
        sync = :git_sync)
    withenv("SYNC_MODE" => "git-sync", "DRIVER" => "job.jl", "DISTSSH_HOSTS" => "") do
        cfg = DistSSHRun.pipeline_config_from_env()
        @test cfg.driver == "job.jl"
    end
end
