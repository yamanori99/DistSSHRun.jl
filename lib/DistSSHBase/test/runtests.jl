using Test
using DistSSHBase

_distsshbase_under_test() = DistSSHBase

include(joinpath(@__DIR__, "support.jl"))

@testset "DistSSHBase" verbose = true begin
    include(joinpath(@__DIR__, "paths.jl"))
    include(joinpath(@__DIR__, "hosts.jl"))
    include(joinpath(@__DIR__, "ssh.jl"))
    include(joinpath(@__DIR__, "shell_quote.jl"))
    include(joinpath(@__DIR__, "detect_julia.jl"))
end
