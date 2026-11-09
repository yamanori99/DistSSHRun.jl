# Setup cores shared by CLI `setup` and API `sync!` (ship + git + ops).

include(joinpath(@__DIR__, "setup", "git_modes.jl"))
include(joinpath(@__DIR__, "setup", "progress.jl"))
include(joinpath(@__DIR__, "setup", "send_list.jl"))
include(joinpath(@__DIR__, "setup", "git.jl"))
include(joinpath(@__DIR__, "setup", "hosts.jl"))
include(joinpath(@__DIR__, "setup", "checks.jl"))
include(joinpath(@__DIR__, "setup", "juliaup.jl"))
include(joinpath(@__DIR__, "setup", "remote_ops.jl"))
include(joinpath(@__DIR__, "setup", "prune.jl"))
