#!/usr/bin/env bash
# Run one diff lint with Julia 1.13 from PATH.
# Instantiates .github/runic so JuliaSyntax loads on a fresh clone.
# Does not install the Runic or JETLS apps.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mode="${1:?mode}"
shift
JULIA=()
if command -v julia >/dev/null 2>&1 && julia +1.13 --startup-file=no -e 'exit(0)' >/dev/null 2>&1; then
  JULIA=(julia +1.13)
elif command -v julia >/dev/null 2>&1; then
  JULIA=(julia)
else
  echo "lint: Julia is not on PATH" >&2
  exit 1
fi
"${JULIA[@]}" --project="${ROOT}/.github/runic" --startup-file=no -e 'using Pkg; Pkg.instantiate()'
exec "${JULIA[@]}" --project="${ROOT}/.github/runic" --startup-file=no "${ROOT}/scripts/lint/diff_lint.jl" "${mode}" "$@"
