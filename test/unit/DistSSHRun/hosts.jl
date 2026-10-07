using Test

@testset "hosts helpers" begin
    @testset "parse_worker_tokens placement" begin
        @test DistSSHRun.parse_worker_tokens(["parent:1"]).parent_workers == 1
        let p = DistSSHRun.parse_worker_tokens(["child:localhost:1"])
            @test p.parent_workers == 0
            @test p.child_workers == Dict("localhost" => 1)
        end
    end
end
