#!/usr/bin/env bash
# Build, reject forbidden proof escapes, audit registry, coverage (julia-in-lean).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

lake build
lake build DistSSHLean.Runtime

python3 scripts/check-proof-escapes.py --self-test
python3 scripts/check-proof-escapes.py

lake env lean Audit.lean | tee .lake/audit.out
julia scripts/check-coverage.jl .lake/audit.out
bash scripts/check-bugs.sh