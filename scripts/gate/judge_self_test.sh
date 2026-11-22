#!/usr/bin/env bash
# Self-test skip_unless semantics used by judge.sh (sourced logic, not full judge matrix).
set -euo pipefail

skip_unless() {
  local flag="$1"
  local reason="$2"
  [[ "${flag}" == true ]] && echo "" || echo "${reason}"
}

[[ "$(skip_unless true "detect base=true")" == "" ]] || {
  echo "judge self-test: skip_unless true" >&2
  exit 1
}
[[ "$(skip_unless false "detect base=true")" == "detect base=true" ]] || {
  echo "judge self-test: skip_unless false" >&2
  exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"${ROOT}/scripts/gate/judge_matrix_verify.sh" >/dev/null
"${ROOT}/scripts/gate/judge_downstream_self_test.sh" >/dev/null

echo "ok"
