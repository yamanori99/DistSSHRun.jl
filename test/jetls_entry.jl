# JETLS entry for unit and integration tests. Pkg.test does not include this
# file; ParallelTestRunner discovers those files from test/runtests.jl.
# Top-level `include`s (inside `@testset`s, not functions) so JETLS follows them.
# Each file already has a `@testset`; do not wrap another around `include`.
# A new unit or integration file needs the same include here.

using Test
using DistSSHRun

include(joinpath(@__DIR__, "support.jl"))

# In-process default matches TTY CLI (`:progress`), not module-load `:verbose`
# or a pipe. Child CLI processes still auto-detect their own stdout.
DistSSHRun.set_kit_verbosity!(:progress)

@testset "DistSSHRun" verbose = true begin
    @testset "unit" verbose = true begin
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "display.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "explain.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "remote.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "shell_quote.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "distributed.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "drive.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "drive", "collect_tree.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "drive", "workers.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "size.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "go.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "plan.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "ride.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "namespace.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "pool.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "module.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "execute.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "argv", "session.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "hosts.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "main_dispatch.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "demos.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "host_project_toml.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "setup_api.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "setup", "checks.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "setup", "hosts.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "setup", "git.jl"))
        include(joinpath(@__DIR__, "unit", "DistSSHRun", "setup", "rsync.jl"))
        include(joinpath(@__DIR__, "unit", "cli", "drive", "args.jl"))
        include(joinpath(@__DIR__, "unit", "cli", "go", "args.jl"))
        include(joinpath(@__DIR__, "unit", "cli", "plan", "args.jl"))
        include(joinpath(@__DIR__, "unit", "cli", "setup", "args.jl"))
        include(joinpath(@__DIR__, "unit", "cli", "up", "args.jl"))
        include(joinpath(@__DIR__, "unit", "cli", "setup", "using_guard.jl"))
        include(joinpath(@__DIR__, "unit", "cli", "setup", "main.jl"))
        include(joinpath(@__DIR__, "unit", "cli", "size", "args.jl"))
        include(joinpath(@__DIR__, "unit", "cli", "pool", "args.jl"))
        include(joinpath(@__DIR__, "unit", "cli", "ride", "args.jl"))
    end

    @testset "integration" verbose = true begin
        include(joinpath(@__DIR__, "integration", "cli", "help.jl"))
        include(joinpath(@__DIR__, "integration", "setup", "exit.jl"))
        include(joinpath(@__DIR__, "integration", "go", "cli.jl"))
        include(joinpath(@__DIR__, "integration", "go", "overlap.jl"))
        include(joinpath(@__DIR__, "integration", "size", "measure.jl"))
        include(joinpath(@__DIR__, "integration", "drive", "local.jl"))
        include(joinpath(@__DIR__, "integration", "drive", "api.jl"))
        include(joinpath(@__DIR__, "integration", "drive", "execute.jl"))
        include(joinpath(@__DIR__, "integration", "drive", "fail.jl"))
        include(joinpath(@__DIR__, "integration", "drive", "pkg.jl"))
        include(joinpath(@__DIR__, "integration", "drive", "log_via_script.jl"))
        include(joinpath(@__DIR__, "integration", "drive", "log_via_module.jl"))
        include(joinpath(@__DIR__, "integration", "drive", "pkg_develop.jl"))
        include(joinpath(@__DIR__, "integration", "demos", "with_kit.jl"))
        include(joinpath(@__DIR__, "integration", "demos", "without_kit.jl"))
    end
end
