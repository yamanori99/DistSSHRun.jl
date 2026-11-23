#!/usr/bin/env bash
# Validate bugs/*.yaml (julia-in-lean pattern). Filing upstream issues is never automated.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 scripts/check_bugs.py