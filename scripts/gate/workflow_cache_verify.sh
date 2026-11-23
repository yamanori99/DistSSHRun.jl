#!/usr/bin/env bash
# Workflows restore Julia depots on all events but must not save julia-cache
# except on push to main (same policy as the JETLS depot). Enforcement is
# workflow/job cache-mode (read vs write); this gate checks the YAML wiring.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOWS="${ROOT}/.github/workflows"

die() {
  echo "workflow_cache_verify: $*" >&2
  exit 1
}

MAIN_ONLY_EXPR='${{ github.event_name == '\''push'\'' && github.ref == '\''refs/heads/main'\'' && '\''write'\'' || '\''read'\'' }}'

has_julia_depot_cache() {
  grep -qE '(julia-actions/cache@|\./\.github/actions/julia-depot-cache)' "$1"
}

workflow_cache_mode_line() {
  awk '
    /^cache-mode:/ {
      print
      exit
    }
    /^jobs:/ { exit }
  ' "$1"
}

job_cache_mode_line() {
  local file="$1"
  local job="$2"
  awk -v want="${job}" '
    $0 ~ "^  " want ":$" { in_job = 1; next }
    in_job && /^  [a-zA-Z0-9_.-]+:$/ { exit }
    in_job && /^    cache-mode:/ { print; exit }
  ' "${file}"
}

jetls_hashfiles_in_workflow() {
  grep -q "jetls-depot-.*hashFiles" "$1"
}

self_test() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  local good="${tmp}/good.yml"
  local bad_pin="${tmp}/bad-pin.yml"
  cat >"${good}" <<EOF
name: x
on: push
cache-mode: ${MAIN_ONLY_EXPR}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/julia-depot-cache
EOF
  cp "${good}" "${bad_pin}"
  echo "      - uses: julia-actions/cache@deadbeef" >>"${bad_pin}"
  workflow_cache_mode_line "${good}" | grep -q 'cache-mode:' || die "self-test: good file"
  if workflow_cache_mode_line "${bad_pin}" >/dev/null && has_julia_depot_cache "${bad_pin}"; then
  :
  fi
  grep -q 'julia-actions/cache@deadbeef' "${bad_pin}" || die "self-test: bad-pin missing pin"
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

fail=0
for file in "${WORKFLOWS}"/*.yml; do
  [[ -f "${file}" ]] || continue
  has_julia_depot_cache "${file}" || continue
  relpath="${file#"${ROOT}/"}"

  if grep -qE '^\s+-\s+uses:\s+julia-actions/cache@' "${file}"; then
    echo "workflow_cache_verify: ${relpath}: use ./.github/actions/julia-depot-cache, not julia-actions/cache" >&2
    fail=1
  fi

  mode="$(workflow_cache_mode_line "${file}")"
  if [[ -z "${mode}" ]]; then
    echo "workflow_cache_verify: ${relpath}: missing workflow-level cache-mode (read or main-only write)" >&2
    fail=1
  elif [[ "${mode}" != "cache-mode: read" && "${mode}" != "cache-mode: ${MAIN_ONLY_EXPR}" ]]; then
    echo "workflow_cache_verify: ${relpath}: cache-mode must be read or the main-only write expression" >&2
    fail=1
  fi

  if jetls_hashfiles_in_workflow "${file}"; then
    echo "workflow_cache_verify: ${relpath}: JETLS depot key must not use hashFiles" >&2
    fail=1
  fi

done

# JETLS save steps must stay main-only.
if grep -q 'Save JETLS depot cache' "${WORKFLOWS}/CI.yml" 2>/dev/null; then
  if ! grep -q "if: github.event_name == 'push' && github.ref == 'refs/heads/main' && steps.jetls-depot-cache.outputs.cache-hit != 'true'" "${WORKFLOWS}/CI.yml"; then
    echo "workflow_cache_verify: CI.yml: JETLS depot save must be push-to-main only" >&2
    fail=1
  fi
fi

if (( fail != 0 )); then
  exit 1
fi
