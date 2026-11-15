using Test
using DistSSHBase

include(joinpath(@__DIR__, "support.jl"))

@testset "DistSSHBase" verbose = true begin
    include(joinpath(@__DIR__, "argv", "cursor.jl"))
    include(joinpath(@__DIR__, "ssh", "budgets.jl"))
    include(joinpath(@__DIR__, "messages", "cli_entry.jl"))
    include(joinpath(@__DIR__, "messages", "cli_exit.jl"))
    include(joinpath(@__DIR__, "messages", "explain.jl"))
    include(joinpath(@__DIR__, "messages", "help.jl"))
    include(joinpath(@__DIR__, "hosts", "hostinfo.jl"))
    include(joinpath(@__DIR__, "hosts", "hosts.jl"))
    include(joinpath(@__DIR__, "ssh", "julia_where.jl"))
    include(joinpath(@__DIR__, "namespace.jl"))
    include(joinpath(@__DIR__, "ssh", "paths.jl"))
    include(joinpath(@__DIR__, "ssh", "state_dir.jl"))
    include(joinpath(@__DIR__, "pkg_env.jl"))
    include(joinpath(@__DIR__, "remote.jl"))
    include(joinpath(@__DIR__, "ssh", "sigint.jl"))
    include(joinpath(@__DIR__, "ssh", "shell_status.jl"))
    include(joinpath(@__DIR__, "ssh", "ssh.jl"))
    include(joinpath(@__DIR__, "shell_quote.jl"))
    include(joinpath(@__DIR__, "detect_julia.jl"))
end
