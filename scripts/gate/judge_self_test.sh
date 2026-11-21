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

echo "ok"
