#!/usr/bin/env julia
# DistSSHRun API demo: run square_file.jl through `pipeline!`
# (optional sync → size! → drive! → collect) instead of the `drive` CLI.
#
# Local (this script):
#
#   julia --project=. distsshkit_demos/with_kit/pipeline_square.jl
#   julia --project=. distsshkit_demos/with_kit/pipeline_square.jl --n 4
#
# Same driver via CLI:
#
#   julia --project=. -m DistSSHRun drive parent:2 distsshkit_demos/with_kit/square_file.jl --n 4

import TOML

# Direct [deps] only. DistSSHKit if the user added it, otherwise DistSSHRun.
function _demo_package()::Symbol
    proj = Base.current_project()
    proj === nothing && return :DistSSHRun
    raw = TOML.parsefile(proj)
    deps = get(raw, "deps", nothing)
    deps isa AbstractDict && haskey(deps, "DistSSHKit") && return :DistSSHKit
    return :DistSSHRun
end

const _DEMO_PACKAGE = _demo_package()
@eval using $_DEMO_PACKAGE

isempty(ARGS) || (length(ARGS) == 2 && ARGS[1] == "--n") ||
    error("pass --n N (a bare number looks like parent:N)")

driver = joinpath(@__DIR__, "square_file.jl")

# Local-only: two Distributed workers on this machine (collect off — outputs stay local).
result = pipeline!(driver, "parent:2"; args = ARGS, collect = false, enable_log = false)

# First-time remotes: setup!, then pipeline! (or drive!).
#
#   session = KitSession(
#       workers=["child:user@host1", "child:user@host2"],
#       remote="/path/to/project",
#       yes=true,
#   )
#   setup!(session, :rsync, :instantiate)
#   # or: setup!(session, :clone; repo="https://…"); setup!(session, :instantiate)
#   result = pipeline!(
#       driver,
#       "child:user@host1:1",
#       "child:user@host2:1";
#       remote="/path/to/project",
#       args=ARGS,
#       # julia=nothing,                  # or path / "auto" (same as CLI --julia)
#   )
#
# Other `pipeline!` keywords (uncomment / edit as needed):
#
#   result = pipeline!(
#       driver,
#       "child:user@host1:1",
#       "child:user@host2:1";   # or pipeline!(driver, ["child:user@host1:1", …]; …)
#       remote="/path/to/project",
#       args=ARGS,
#       collect=true,                   # false → skip; path → collect root
#       # project=pwd(),
#       # hosts_file="hosts.txt",       # extra parent:N / child:NAME:N lines
#       # yes=true,                     # skip confirm prompts (API default)
#       # quiet=false,
#       # verbosity=nothing,            # :quiet | :progress | :verbose
#       # sync=false,                   # or :sync / :rsync (rsync: empty remote only)
#       # collect_merge=false,          # merge into existing collect tree
#       # output_dir=nothing,           # also used as collect root when set
#       # enable_log=true,
#       # log_dir=nothing,
#       # package=nothing,              # package name hint on workers
#       # skip_hash_check=nothing,      # false → require remote git parity
#       # mem_headroom=0.75,
#       # parent_gb=0.4,
#   )

report_pipeline_errors(result) || exit(1)
println("pipeline! ok  (driver=", basename(driver), ")")
