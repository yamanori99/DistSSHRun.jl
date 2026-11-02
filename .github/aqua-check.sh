#!/usr/bin/env bash
# Latest registered Aqua in a temp env (not test/Project.toml). Same as CI.
#
#   ./.github/aqua-check.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

exec julia --startup-file=no -e '
using Pkg
Pkg.activate(; temp=true)
Pkg.develop(PackageSpec(; path=pwd()))
Pkg.add("Aqua")
using Aqua, DistSSHRun
# GitIgnore is Base.require-d when the send list is built, not at import
# (workers may precompile DistSSHRun from LOAD_PATH without that dep).
Aqua.test_all(DistSSHRun; stale_deps = (ignore = [:GitIgnore],))
'
