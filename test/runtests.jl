#!/usr/bin/env julia
# DistSSHRun Pkg.test() entry: unit + integration (Aqua is CI-only).
# Does not include test/e2e.jl (real SSH; DISTSSHKIT_SSH_E2E=1 / up.sh --e2e).
# From a standalone kit checkout (this directory as the active project):
#   julia --project=. -e 'using Pkg; Pkg.test()'
#   julia --project=. test/runtests.jl
#
# Each test file runs in its own process (ParallelTestRunner). JETLS follows
# the includes in test/jetls_entry.jl, not this file. A new unit or integration
# file is discovered here; add the same include to jetls_entry.jl.
# Maintainer checks:
#   CONTRIBUTING.md ("Before opening a PR")
#   ./.github/jetls-check.sh

using DistSSHRun
using ParallelTestRunner

# Evaluated in each test sandbox. support.jl skips its include when the name
# is already on Main, so this must not run in the worker's Main first.
const init_code = quote
    using Test
    using DistSSHRun
    include(joinpath(@__DIR__, "support.jl"))
    # Workers are reused across files. setup! and apply_session_env! write
    # these, so a later file would otherwise see the previous file's session.
    delete!(ENV, "DISTRIBUTED_PROJECT_ROOT")
    delete!(ENV, "DISTRIBUTED_REMOTE_PROJECT_ROOT")
    DistSSHRun.set_kit_verbosity!(:progress)
    DistSSHRun.set_kit_output_quiet!(false)
    DistSSHRun.set_kit_noninteractive!(false)
end

testsuite = find_tests(@__DIR__)
for key in collect(keys(testsuite))
    if key == "e2e" || key == "jetls_entry" ||
            startswith(key, "support") || startswith(key, "fixtures") ||
            key == "integration/drive/api" || key == "integration/drive/execute"
        delete!(testsuite, key)
    end
end
# Same process: execute.jl's warn-overwrite check follows api.jl's include.
# Not a file, so find_tests does not discover it twice.
testsuite["integration/drive/in_process"] = quote
    include(joinpath(@__DIR__, "integration", "drive", "api.jl"))
    include(joinpath(@__DIR__, "integration", "drive", "execute.jl"))
end

args = parse_args(ARGS)
filter_tests!(testsuite, args)
# Files that start a child Julia or addprocs. Four PTR jobs on a 16 GB
# runner stack on that width and the children die, so the suite stays as
# slow as the old serial run. Light unit and CLI argument files stay parallel.
runtests(
    DistSSHRun, args;
    testsuite, init_code,
    serial = [
        "integration/go/overlap",
        "integration/go/cli",
        "integration/drive/in_process",
        "unit/DistSSHRun/ride",
        "unit/DistSSHRun/drive/workers",
        "integration/demos/with_kit",
        "integration/demos/without_kit",
        "integration/drive/pkg",
        "integration/drive/local",
        "integration/drive/pkg_develop",
        "integration/drive/log_via_module",
        "integration/drive/log_via_script",
        "integration/drive/fail",
        "integration/cli/help",
        "integration/setup/exit",
        "integration/size/measure",
    ],
)
