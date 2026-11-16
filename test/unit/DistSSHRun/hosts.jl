using Test

@testset "hosts helpers" begin
    @testset "parse_worker_tokens placement" begin
        @test DistSSHRun.parse_worker_tokens(["1*localhost"]; head_workers = 1).head_workers == 1
        let p = DistSSHRun.parse_worker_tokens(["1*localhost"])
            @test p.head_workers == 0
            @test p.child_workers == Dict("localhost" => 1)
        end
    end
end
