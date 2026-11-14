#!/usr/bin/env julia
# DistSSHRun Pkg.test() entry: unit + integration (Aqua is CI-only).
# Does not include test/e2e.jl (real SSH; DISTSSH_SSH_E2E=1 / up.sh --e2e).
# From a standalone kit checkout (this directory as the active project):
#   julia --project=. -e 'using Pkg; Pkg.test()'
#   julia --project=. test/runtests.jl
#
# Top-level `include`s (inside `@testset`s, not functions) so JETLS follows them.
# Each file already has a `@testset`; do not wrap another around `include`.
# New unit/integration files must be added here. Maintainer checks:
#   CONTRIBUTING.md ("Before opening a PR")
#   ./.github/jetls-check.sh

# Startup project for helper children. Captured before any `include`: an
# in-process `drive!` activates the host and must not become `--project`.
const TEST_PROJECT = let active = Base.active_project()
    active === nothing && error("test/runtests.jl: Base.active_project() is nothing")
    String(active)
end

using Test
using DistSSHRun

include(joinpath(@__DIR__, "support.jl"))
if !isdefined(Main, :_binding_world_age_warning_text)
    include(joinpath(@__DIR__, "support", "binding_world_stderr.jl"))
end

# In-process default matches TTY CLI (`:progress`), not module-load `:verbose`
# or a pipe. Child CLI processes still auto-detect their own stdout.
DistSSHRun.set_kit_verbosity!(:progress)

# Keep `include(joinpath(@__DIR__, …))` at this top level (JETLS). The banner
# counts `_runtest_announce` calls in this file, so adding one updates `[i/N]`.
const _RUNTEST_N = let n = count(eachline(@__FILE__)) do line
        return occursin(r"^\s*_runtest_include\(", line)
    end
    n > 0 || error("test/runtests.jl: no _runtest_include calls")
    n
end
const _RUNTEST_I = Ref(0)
function _runtest_announce(rel::AbstractString)
    _RUNTEST_I[] += 1
    println("[$(_RUNTEST_I[])/$_RUNTEST_N]  $rel")
    flush(stdout)
    return nothing
end

function _runtest_include(rel::AbstractString, path::AbstractString)
    _runtest_announce(rel)
    mktemp() do err_path, err_io
        redirect_stderr(err_io) do
            include(path)
        end
        flush(err_io)
        text = read(err_path, String)
        print(stderr, text)
        _assert_no_binding_world_stderr!(rel, text)
    end
    return nothing
end

function _distssh_test_group_enabled(sym::Symbol)::Bool
    raw = strip(get(ENV, "DISTSSH_TEST_GROUP", ""))
    isempty(raw) && return true
    g = lowercase(raw)
    g == "unit" && return sym === :unit
    g == "integration" && return sym === :integration
    error("test/runtests.jl: invalid DISTSSH_TEST_GROUP=$(repr(raw)); want unit, integration, or unset")
end

@testset "DistSSHRun" verbose = true begin
    if _distssh_test_group_enabled(:unit)
        @testset "unit" verbose = true begin
            _runtest_include("unit/DistSSHRun/messages/display.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "messages", "display.jl"))
            _runtest_include("unit/DistSSHRun/explain.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "explain.jl"))
            _runtest_include("unit/DistSSHRun/infra/remote.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "remote.jl"))
            _runtest_include("unit/DistSSHRun/infra/distributed.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "distributed.jl"))
            _runtest_include("unit/DistSSHRun/drive.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "drive.jl"))
            _runtest_include("unit/DistSSHRun/core/drive/collect_tree.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "drive", "collect_tree.jl"))
            _runtest_include("unit/DistSSHRun/core/drive/warn_newline.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "drive", "warn_newline.jl"))
            _runtest_include("unit/DistSSHRun/core/drive/progress_nolog_stdio.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "drive", "progress_nolog_stdio.jl"))
            _runtest_include("unit/DistSSHRun/core/drive/progress_tty_payload.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "drive", "progress_tty_payload.jl"))
            if !_distsshrun_short_skip("unit/DistSSHRun/core/drive/workers.jl")
                _runtest_include("unit/DistSSHRun/core/drive/workers.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "drive", "workers.jl"))
            else
                _runtest_announce("unit/DistSSHRun/core/drive/workers.jl")
            end
            _runtest_include("unit/DistSSHRun/options/heartbeat.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "options", "heartbeat.jl"))
            _runtest_include("unit/DistSSHRun/infra/worker_plan.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "worker_plan.jl"))
            _runtest_include("unit/DistSSHRun/hostinfo.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "hostinfo.jl"))
            _runtest_include("unit/DistSSHRun/go.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "go.jl"))
            _runtest_include("unit/DistSSHRun/ride.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "ride.jl"))
            _runtest_include("unit/DistSSHRun/namespace.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "namespace.jl"))
            _runtest_include("unit/DistSSHRun/pool.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "pool.jl"))
            _runtest_include("unit/DistSSHRun/module.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "module.jl"))
            _runtest_include("unit/DistSSHRun/infra/launch.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "launch.jl"))
            if !_distsshrun_short_skip("unit/DistSSHRun/execute.jl")
                _runtest_include("unit/DistSSHRun/execute.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "execute.jl"))
            else
                _runtest_announce("unit/DistSSHRun/execute.jl")
            end
            _runtest_include("unit/DistSSHRun/provenance.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "provenance.jl"))
            _runtest_include("unit/DistSSHRun/argv/session.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "argv", "session.jl"))
            _runtest_include("unit/DistSSHRun/hosts.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "hosts.jl"))
            _runtest_include("unit/DistSSHRun/main_dispatch.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "main_dispatch.jl"))
            _runtest_include("unit/DistSSHRun/downstream_public.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "downstream_public.jl"))
            _runtest_include("unit/DistSSHRun/infra/demos.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "demos.jl"))
            _runtest_include("unit/DistSSHRun/host_project_toml.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "host_project_toml.jl"))
            _runtest_include("unit/DistSSHRun/setup_api.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "setup_api.jl"))
            _runtest_include("unit/DistSSHRun/core/setup/status_summary.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "setup", "status_summary.jl"))
            if !_distsshrun_short_skip("unit/DistSSHRun/core/setup/checks.jl")
                _runtest_include("unit/DistSSHRun/core/setup/checks.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "setup", "checks.jl"))
            else
                _runtest_announce("unit/DistSSHRun/core/setup/checks.jl")
            end
            _runtest_include("unit/DistSSHRun/core/setup/instantiate.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "setup", "instantiate.jl"))
            _runtest_include("unit/DistSSHRun/core/setup/hosts.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "setup", "hosts.jl"))
            _runtest_include("unit/DistSSHRun/core/setup/git.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "setup", "git.jl"))
            _runtest_include("unit/DistSSHRun/core/setup/tree_copy.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "setup", "tree_copy.jl"))
            _runtest_include("unit/DistSSHRun/infra/ship.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "ship.jl"))
            _runtest_include("unit/DistSSHRun/infra/deploy_record.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "deploy_record.jl"))
            _runtest_include("unit/DistSSHRun/infra/run_transfer_removed.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "run_transfer_removed.jl"))
            _runtest_include("unit/DistSSHRun/infra/source_selection.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "source_selection.jl"))
            _runtest_include("unit/DistSSHRun/infra/ship_list.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "ship_list.jl"))
            _runtest_include("unit/DistSSHRun/infra/ship_manifest_oracle.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "ship_manifest_oracle.jl"))
            _runtest_include("unit/DistSSHRun/infra/ship_fake_ssh_child_env.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "ship_fake_ssh_child_env.jl"))
            _runtest_include("unit/DistSSHRun/infra/ship_dest.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "ship_dest.jl"))
            _runtest_include("unit/DistSSHRun/infra/ship_engine_contract.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "infra", "ship_engine_contract.jl"))
            if !_distsshrun_short_skip("unit/DistSSHRun/core/setup/send_list.jl")
                _runtest_include("unit/DistSSHRun/core/setup/send_list.jl", joinpath(@__DIR__, "unit", "DistSSHRun", "core", "setup", "send_list.jl"))
            else
                _runtest_announce("unit/DistSSHRun/core/setup/send_list.jl")
            end
            _runtest_include("unit/cli/drive/args.jl", joinpath(@__DIR__, "unit", "cli", "drive", "args.jl"))
            _runtest_include("unit/cli/go/args.jl", joinpath(@__DIR__, "unit", "cli", "go", "args.jl"))
            _runtest_include("unit/cli/setup/args.jl", joinpath(@__DIR__, "unit", "cli", "setup", "args.jl"))
            _runtest_include("unit/cli/up/args.jl", joinpath(@__DIR__, "unit", "cli", "up", "args.jl"))
            _runtest_include("unit/cli/setup/using_guard.jl", joinpath(@__DIR__, "unit", "cli", "setup", "using_guard.jl"))
            _runtest_include("unit/cli/setup/main.jl", joinpath(@__DIR__, "unit", "cli", "setup", "main.jl"))
            _runtest_include("unit/cli/hostinfo/args.jl", joinpath(@__DIR__, "unit", "cli", "hostinfo", "args.jl"))
            _runtest_include("unit/cli/pool/args.jl", joinpath(@__DIR__, "unit", "cli", "pool", "args.jl"))
            _runtest_include("unit/cli/ride/args.jl", joinpath(@__DIR__, "unit", "cli", "ride", "args.jl"))
            _runtest_include("unit/cli/subcommands_main.jl", joinpath(@__DIR__, "unit", "cli", "subcommands_main.jl"))
        end
    end # unit group

    if _distssh_test_group_enabled(:integration)
        @testset "integration" verbose = true begin
            _runtest_include("integration/DistSSHRun/vendor.jl", joinpath(@__DIR__, "integration", "DistSSHRun", "vendor.jl"))
            _runtest_include("integration/DistSSHRun/cli_nomanifest.jl", joinpath(@__DIR__, "integration", "DistSSHRun", "cli_nomanifest.jl"))
            _runtest_include("integration/DistSSHRun/env_verify.jl", joinpath(@__DIR__, "integration", "DistSSHRun", "env_verify.jl"))
            if !_distsshrun_short_skip("integration/cli/help.jl")
                _runtest_include("integration/cli/help.jl", joinpath(@__DIR__, "integration", "cli", "help.jl"))
            else
                _runtest_announce("integration/cli/help.jl")
            end
            if !_distsshrun_short_skip("integration/setup/exit.jl")
                _runtest_include("integration/setup/exit.jl", joinpath(@__DIR__, "integration", "setup", "exit.jl"))
            else
                _runtest_announce("integration/setup/exit.jl")
            end
            if !_distsshrun_short_skip("integration/setup/progress_tty.jl")
                _runtest_include("integration/setup/progress_tty.jl", joinpath(@__DIR__, "integration", "setup", "progress_tty.jl"))
            else
                _runtest_announce("integration/setup/progress_tty.jl")
            end
            _runtest_include("integration/go/cli.jl", joinpath(@__DIR__, "integration", "go", "cli.jl"))
            _runtest_include("integration/go/overlap.jl", joinpath(@__DIR__, "integration", "go", "overlap.jl"))
            _runtest_include("integration/drive/local.jl", joinpath(@__DIR__, "integration", "drive", "local.jl"))
            _runtest_include("integration/drive/api.jl", joinpath(@__DIR__, "integration", "drive", "api.jl"))
            _runtest_include("integration/cli/project.jl", joinpath(@__DIR__, "integration", "cli", "project.jl"))
            if !_distsshrun_short_skip("integration/drive/progress_tty.jl")
                _runtest_include("integration/drive/progress_tty.jl", joinpath(@__DIR__, "integration", "drive", "progress_tty.jl"))
            else
                _runtest_announce("integration/drive/progress_tty.jl")
            end
            if !_distsshrun_short_skip("integration/drive/execute.jl")
                _runtest_include("integration/drive/execute.jl", joinpath(@__DIR__, "integration", "drive", "execute.jl"))
            else
                _runtest_announce("integration/drive/execute.jl")
            end
            _runtest_include("integration/drive/fail.jl", joinpath(@__DIR__, "integration", "drive", "fail.jl"))
            _runtest_include("integration/drive/sigint.jl", joinpath(@__DIR__, "integration", "drive", "sigint.jl"))
            if !_distsshrun_short_skip("integration/drive/interrupt_grace.jl")
                _runtest_include("integration/drive/interrupt_grace.jl", joinpath(@__DIR__, "integration", "drive", "interrupt_grace.jl"))
            else
                _runtest_announce("integration/drive/interrupt_grace.jl")
            end
            if !_distsshrun_short_skip("integration/drive/pkg.jl")
                _runtest_include("integration/drive/pkg.jl", joinpath(@__DIR__, "integration", "drive", "pkg.jl"))
            else
                _runtest_announce("integration/drive/pkg.jl")
            end
            if !_distsshrun_short_skip("integration/drive/log_via_script.jl")
                _runtest_include("integration/drive/log_via_script.jl", joinpath(@__DIR__, "integration", "drive", "log_via_script.jl"))
            else
                _runtest_announce("integration/drive/log_via_script.jl")
            end
            if !_distsshrun_short_skip("integration/drive/log_via_module.jl")
                _runtest_include("integration/drive/log_via_module.jl", joinpath(@__DIR__, "integration", "drive", "log_via_module.jl"))
            else
                _runtest_announce("integration/drive/log_via_module.jl")
            end
            if !_distsshrun_short_skip("integration/drive/pkg_develop.jl")
                _runtest_include("integration/drive/pkg_develop.jl", joinpath(@__DIR__, "integration", "drive", "pkg_develop.jl"))
            else
                _runtest_announce("integration/drive/pkg_develop.jl")
            end
            if !_distsshrun_short_skip("integration/demos/with_kit.jl")
                _runtest_include("integration/demos/with_kit.jl", joinpath(@__DIR__, "integration", "demos", "with_kit.jl"))
            else
                _runtest_announce("integration/demos/with_kit.jl")
            end
            if !_distsshrun_short_skip("integration/demos/without_kit.jl")
                _runtest_include("integration/demos/without_kit.jl", joinpath(@__DIR__, "integration", "demos", "without_kit.jl"))
            else
                _runtest_announce("integration/demos/without_kit.jl")
            end
        end
    end # integration group
end
