using Test
using DistSSHUp

_distsshup_under_test() = DistSSHUp

include(joinpath(@__DIR__, "support.jl"))

@testset "DistSSHUp" verbose = true begin
    include(joinpath(@__DIR__, "local.jl"))
end
