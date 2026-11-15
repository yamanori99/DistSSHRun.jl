#!/usr/bin/env bash
# Build, reject forbidden proof escapes, audit registry, coverage (julia-in-lean).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT
lake build 2>&1 | tee "$build_log"
if grep -qE 'linter\.(unusedSimpArgs|unnecessarySimpa)' "$build_log"; then
  echo "FAIL Lean linter warnings (unusedSimpArgs / unnecessarySimpa):"
  grep -E 'linter\.(unusedSimpArgs|unnecessarySimpa)' "$build_log"
  exit 1
fi
echo "LINT OK"
lake build DistSSHLean.Runtime

python3 scripts/check-proof-escapes.py --self-test
python3 scripts/check-proof-escapes.py

if ! lake env lean Report.lean | cmp -s registry.tsv -; then
  echo "FAIL registry.tsv out of date (run: lake env lean Report.lean > registry.tsv)"
  lake env lean Report.lean | diff -u registry.tsv - | tail -30
  exit 1
fi
echo "REGISTRY OK"

lake env lean Audit.lean | tee .lake/audit.out
lake env lean AxiomReport.lean
julia scripts/check-coverage.jl .lake/audit.out
python3 scripts/check_bugs.py --self-test
bash scripts/check-bugs.sh