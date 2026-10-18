using Test
using DistSSHBase

include(joinpath(@__DIR__, "support.jl"))

@testset "DistSSHBase" verbose = true begin
    include(joinpath(@__DIR__, "argv.jl"))
    include(joinpath(@__DIR__, "cli_entry.jl"))
    include(joinpath(@__DIR__, "explain.jl"))
    include(joinpath(@__DIR__, "help.jl"))
    include(joinpath(@__DIR__, "hosts.jl"))
    include(joinpath(@__DIR__, "julia_where.jl"))
    include(joinpath(@__DIR__, "namespace.jl"))
    include(joinpath(@__DIR__, "paths.jl"))
    include(joinpath(@__DIR__, "pkg_env.jl"))
    include(joinpath(@__DIR__, "remote.jl"))
    include(joinpath(@__DIR__, "sigint.jl"))
    include(joinpath(@__DIR__, "ssh.jl"))
    include(joinpath(@__DIR__, "shell_quote.jl"))
    include(joinpath(@__DIR__, "detect_julia.jl"))
end
