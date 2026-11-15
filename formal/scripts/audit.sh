#!/usr/bin/env bash
# Build, reject forbidden proof escapes, audit registry, coverage (julia-in-lean).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lake build
lake build DistSSHLean.Runtime

python3 scripts/check-proof-escapes.py --self-test
python3 scripts/check-proof-escapes.py

if ! lake env lean Report.lean | cmp -s registry.tsv; then
  echo "FAIL registry.tsv out of date (run: lake env lean Report.lean > registry.tsv)"
  lake env lean Report.lean | diff -u registry.tsv - | tail -30
  exit 1
fi
echo "REGISTRY OK"

lake env lean Audit.lean | tee .lake/audit.out
julia scripts/check-coverage.jl .lake/audit.out
python3 scripts/check_bugs.py --self-test
bash scripts/check-bugs.sh