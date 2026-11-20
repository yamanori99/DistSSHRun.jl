#!/usr/bin/env bash
# Run one diff lint with Julia 1.13 from PATH.
# Instantiates .github/runic so JuliaSyntax loads on a fresh clone.
# Does not install the Runic or JETLS apps.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../julia.sh
source "${ROOT}/scripts/julia.sh"
if [[ $# -lt 1 ]]; then
  echo "usage: run.sh <mode> [args]" >&2
  exit 2
fi
mode="${1}"
shift
use_julia_1_13 || exit 1
"${JULIA[@]}" --project="${ROOT}/.github/runic" --startup-file=no -e 'using Pkg; Pkg.instantiate()'
exec "${JULIA[@]}" --project="${ROOT}/.github/runic" --startup-file=no "${ROOT}/scripts/lint/diff_lint.jl" "${mode}" "$@"
