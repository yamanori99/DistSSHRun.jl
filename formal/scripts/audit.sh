#!/usr/bin/env bash
# Build, reject forbidden proof escapes, audit registry, coverage (julia-in-lean).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lake build

if grep -rnwE 'sorry|admit|native_decide|bv_decide|ofReduceBool' --include='*.lean' DistSSHLean DistSSHLean.lean Audit.lean Report.lean ShellStatusBatch.lean \
        | grep -v '^Audit.lean:'; then
  echo "FAIL forbidden proof escape found (see lines above)"
  exit 1
fi

if grep -rnE '^\s*axiom\s' --include='*.lean' DistSSHLean DistSSHLean.lean Audit.lean Report.lean ShellStatusBatch.lean; then
  echo "FAIL user axiom declaration found (see lines above)"
  exit 1
fi

lake env lean Audit.lean | tee .lake/audit.out
julia scripts/check-coverage.jl .lake/audit.out
bash scripts/check-bugs.sh