using Test
using DistSSHUp
using DistSSHBase

_distsshup_under_test() = DistSSHUp

include(joinpath(@__DIR__, "..", "..", "DistSSHBase", "test", "support.jl"))
include(joinpath(@__DIR__, "support.jl"))

@testset "DistSSHUp" verbose = true begin
    include(joinpath(@__DIR__, "local.jl"))
end
