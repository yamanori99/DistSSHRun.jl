#!/usr/bin/env bash
# Build, reject forbidden proof escapes and user axioms, then run Audit.lean.
# Pattern: https://github.com/MilesCranmer/julia-in-lean (dynamicexpressions/scripts/audit.sh)
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