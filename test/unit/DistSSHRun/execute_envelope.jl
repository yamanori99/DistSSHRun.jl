using DistSSHRun
using Test

@testset "ExecuteEnvelope in-process" begin
    withenv("DISTRIBUTED_PROJECT_ROOT" => pwd()) do
        env = DistSSHRun.execute_envelope(:go, "missing-$(tempname()).jl", ["parent:1"])
        @test env.kind === :go
        err = try
            DistSSHRun.execute!(env; detached = false)
            nothing
        catch e
            e
        end
        @test err !== nothing
    end
end
