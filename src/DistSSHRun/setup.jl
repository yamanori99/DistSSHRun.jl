# Setup cores shared by CLI `setup` and API `sync!` (ship + git + ops).

include(joinpath(@__DIR__, "core", "setup", "git_modes.jl"))
include(joinpath(@__DIR__, "core", "setup", "progress.jl"))
include(joinpath(@__DIR__, "core", "setup", "send_list.jl"))
include(joinpath(@__DIR__, "core", "setup", "git.jl"))
include(joinpath(@__DIR__, "core", "setup", "hosts.jl"))
include(joinpath(@__DIR__, "core", "setup", "checks.jl"))
include(joinpath(@__DIR__, "core", "setup", "juliaup.jl"))
include(joinpath(@__DIR__, "core", "setup", "remote_ops.jl"))
include(joinpath(@__DIR__, "core", "setup", "prune.jl"))
