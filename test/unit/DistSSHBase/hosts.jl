using Test

let _BASE = DistSSHRun.DistSSHBase
    @testset "placement token" begin
        @test_throws ArgumentError _BASE.parse_placement_token("child:-oBatchMode=yes")
    end
end
