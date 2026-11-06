using Test
using DistSSHBase
using DistSSHSize

@testset "DistSSHSize" verbose = true begin
    @test nameof(DistSSHSize) === :DistSSHSize
    @test isdefined(DistSSHSize, :DistSSHBase)
    include(joinpath(@__DIR__, "worker_plan.jl"))
end
