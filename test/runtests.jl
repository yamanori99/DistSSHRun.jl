#!/usr/bin/env julia
# DistSSHRun Pkg.test() entry: unit + integration (Aqua is CI-only).
# Does not include test/e2e.jl (real SSH; DISTSSHKIT_SSH_E2E=1 / up.sh --e2e).
# From a standalone kit checkout (this directory as the active project):
#   julia --project=. -e 'using Pkg; Pkg.test()'
#   julia --project=. test/runtests.jl
#
# Top-level `include`s (inside `@testset`s, not functions) so JETLS follows them.
# Each file already has a `@testset`; do not wrap another around `include`.
# New unit/integration files must be added here. Maintainer checks:
#   CONTRIBUTING.md ("Before opening a PR")
#   ./.github/jetls-check.sh

using Test
import DistSSHBase
using DistSSHRun

include(joinpath(@__DIR__, "support.jl"))

# In-process default matches TTY CLI (`:progress`), not module-load `:verbose`
# or a pipe. Child CLI processes still auto-detect their own stdout.
DistSSHRun.set_kit_verbosity!(:progress)

# Keep `include(joinpath(@__DIR__, …))` at this top level (JETLS). Only the
# banner is counted. Update `_RUNTEST_N` when adding a file below.
const _RUNTEST_N = 50
const _RUNTEST_I = Ref(0)
function _runtest_announce(rel::AbstractString)
    _RUNTEST_I[] += 1
    println("[$(_RUNTEST_I[])/$_RUNTEST_N]  $rel")
    flush(stdout)
    return nothing
end

@testset "DistSSHRun" verbose = true begin
    @testset "unit" verbose = true begin
        _runtest_announce("unit/DistSSHRun/display.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "display.jl"))
        _runtest_announce("unit/DistSSHRun/explain.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "explain.jl"))
        _runtest_announce("unit/DistSSHRun/remote.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "remote.jl"))
        _runtest_announce("unit/DistSSHRun/distributed.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "distributed.jl"))
        _runtest_announce("unit/DistSSHRun/drive.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "drive.jl"))
        _runtest_announce("unit/DistSSHRun/drive/collect_tree.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "drive", "collect_tree.jl"))
        _runtest_announce("unit/DistSSHRun/drive/workers.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "drive", "workers.jl"))
        _runtest_announce("unit/DistSSHRun/size.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "size.jl"))
        _runtest_announce("unit/DistSSHRun/go.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "go.jl"))
        _runtest_announce("unit/DistSSHRun/plan.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "plan.jl"))
        _runtest_announce("unit/DistSSHRun/ride.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "ride.jl"))
        _runtest_announce("unit/DistSSHRun/namespace.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "namespace.jl"))
        _runtest_announce("unit/DistSSHRun/pool.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "pool.jl"))
        _runtest_announce("unit/DistSSHRun/module.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "module.jl"))
        _runtest_announce("unit/DistSSHRun/execute.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "execute.jl"))
        _runtest_announce("unit/DistSSHRun/argv/session.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "argv", "session.jl"))
        _runtest_announce("unit/DistSSHRun/hosts.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "hosts.jl"))
        _runtest_announce("unit/DistSSHRun/main_dispatch.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "main_dispatch.jl"))
        _runtest_announce("unit/DistSSHRun/demos.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "demos.jl"))
        _runtest_announce("unit/DistSSHRun/host_project_toml.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "host_project_toml.jl"))
        _runtest_announce("unit/DistSSHRun/setup_api.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "setup_api.jl"))
        _runtest_announce("unit/DistSSHRun/setup/checks.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "setup", "checks.jl"))
        _runtest_announce("unit/DistSSHRun/setup/hosts.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "setup", "hosts.jl"))
        _runtest_announce("unit/DistSSHRun/setup/git.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "setup", "git.jl"))
        _runtest_announce("unit/DistSSHRun/setup/rsync.jl")
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "setup", "rsync.jl"))
        _runtest_announce("unit/cli/drive/args.jl")
        include(joinpath(@__DIR__, "unit", "cli", "drive", "args.jl"))
        _runtest_announce("unit/cli/go/args.jl")
        include(joinpath(@__DIR__, "unit", "cli", "go", "args.jl"))
        _runtest_announce("unit/cli/plan/args.jl")
        include(joinpath(@__DIR__, "unit", "cli", "plan", "args.jl"))
        _runtest_announce("unit/cli/setup/args.jl")
        include(joinpath(@__DIR__, "unit", "cli", "setup", "args.jl"))
        _runtest_announce("unit/cli/up/args.jl")
        include(joinpath(@__DIR__, "unit", "cli", "up", "args.jl"))
        _runtest_announce("unit/cli/setup/using_guard.jl")
        include(joinpath(@__DIR__, "unit", "cli", "setup", "using_guard.jl"))
        _runtest_announce("unit/cli/setup/main.jl")
        include(joinpath(@__DIR__, "unit", "cli", "setup", "main.jl"))
        _runtest_announce("unit/cli/size/args.jl")
        include(joinpath(@__DIR__, "unit", "cli", "size", "args.jl"))
        _runtest_announce("unit/cli/pool/args.jl")
        include(joinpath(@__DIR__, "unit", "cli", "pool", "args.jl"))
        _runtest_announce("unit/cli/ride/args.jl")
        include(joinpath(@__DIR__, "unit", "cli", "ride", "args.jl"))
    end

    @testset "integration" verbose = true begin
        _runtest_announce("integration/cli/help.jl")
        include(joinpath(@__DIR__, "integration", "cli", "help.jl"))
        _runtest_announce("integration/setup/exit.jl")
        include(joinpath(@__DIR__, "integration", "setup", "exit.jl"))
        _runtest_announce("integration/go/cli.jl")
        include(joinpath(@__DIR__, "integration", "go", "cli.jl"))
        _runtest_announce("integration/go/overlap.jl")
        include(joinpath(@__DIR__, "integration", "go", "overlap.jl"))
        _runtest_announce("integration/size/measure.jl")
        include(joinpath(@__DIR__, "integration", "size", "measure.jl"))
        _runtest_announce("integration/drive/local.jl")
        include(joinpath(@__DIR__, "integration", "drive", "local.jl"))
        _runtest_announce("integration/drive/api.jl")
        include(joinpath(@__DIR__, "integration", "drive", "api.jl"))
        _runtest_announce("integration/drive/execute.jl")
        include(joinpath(@__DIR__, "integration", "drive", "execute.jl"))
        _runtest_announce("integration/drive/fail.jl")
        include(joinpath(@__DIR__, "integration", "drive", "fail.jl"))
        _runtest_announce("integration/drive/pkg.jl")
        include(joinpath(@__DIR__, "integration", "drive", "pkg.jl"))
        _runtest_announce("integration/drive/log_via_script.jl")
        include(joinpath(@__DIR__, "integration", "drive", "log_via_script.jl"))
        _runtest_announce("integration/drive/log_via_module.jl")
        include(joinpath(@__DIR__, "integration", "drive", "log_via_module.jl"))
        _runtest_announce("integration/drive/pkg_develop.jl")
        include(joinpath(@__DIR__, "integration", "drive", "pkg_develop.jl"))
        _runtest_announce("integration/demos/with_kit.jl")
        include(joinpath(@__DIR__, "integration", "demos", "with_kit.jl"))
        _runtest_announce("integration/demos/without_kit.jl")
        include(joinpath(@__DIR__, "integration", "demos", "without_kit.jl"))
    end
end
