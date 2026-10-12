using Test

if !isdefined(@__MODULE__, :B)
    const B = DistSSHRun.DistSSHBase
end

@testset "placement token" begin
    @test_throws ArgumentError B.parse_placement_token("child:-oBatchMode=yes")
end
