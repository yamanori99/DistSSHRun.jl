#!/usr/bin/env bash
# Run one diff lint with Julia 1.13 from PATH. The project is the repo pin.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mode="${1:?mode}"
if command -v julia >/dev/null 2>&1 && julia +1.13 --startup-file=no -e 'exit(0)' >/dev/null 2>&1; then
  exec julia +1.13 --project="${ROOT}/.github/runic" --startup-file=no "${ROOT}/scripts/lint/diff_lint.jl" "${mode}"
fi
exec julia --project="${ROOT}/.github/runic" --startup-file=no "${ROOT}/scripts/lint/diff_lint.jl" "${mode}"
