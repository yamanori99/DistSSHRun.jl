using Test
using DistSSHBase
using DistSSHUp

include(joinpath(@__DIR__, "support.jl"))

@testset "DistSSHUp" verbose = true begin
    include(joinpath(@__DIR__, "version.jl"))
    include(joinpath(@__DIR__, "status.jl"))
    include(joinpath(@__DIR__, "remote.jl"))
    include(joinpath(@__DIR__, "local.jl"))
    include(joinpath(@__DIR__, "hosts.jl"))
    include(joinpath(@__DIR__, "runtime.jl"))
end
