using Test
using DistSSHBase
using DistSSHSize

@testset "DistSSHSize" verbose = true begin
    @test nameof(DistSSHSize) === :DistSSHSize
    @test isdefined(DistSSHSize, :DistSSHBase)
end
