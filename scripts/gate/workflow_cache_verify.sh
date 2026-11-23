#!/usr/bin/env bash
# Julia depots: restore on all events, save only on push to main (JETLS depot + julia-depot-cache).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOWS="${ROOT}/.github/workflows"
WRAPPER="${ROOT}/.github/actions/julia-depot-cache/action.yml"

die() {
  echo "workflow_cache_verify: $*" >&2
  exit 1
}

MAIN_SAVE_IF="github.event_name == 'push' && github.ref == 'refs/heads/main'"

has_julia_depot_cache() {
  grep -q './\.github/actions/julia-depot-cache' "$1"
}

jetls_hashfiles_in_workflow() {
  grep -q 'jetls-depot-.*hashFiles' "$1"
}

check_wrapper_save() {
  grep -qF 'Save Julia depot cache' "${WRAPPER}" || die "julia-depot-cache: missing Save Julia depot cache step"
  grep -qF "${MAIN_SAVE_IF}" "${WRAPPER}" || die "julia-depot-cache: save step must gate on push to main"
  grep -q 'actions/cache/save@' "${WRAPPER}" || die "julia-depot-cache: must use actions/cache/save"
  grep -q 'actions/cache/restore@' "${WRAPPER}" || die "julia-depot-cache: must use actions/cache/restore"
  grep -q 'julia-actions/cache@' "${WRAPPER}" && die "julia-depot-cache: must not call julia-actions/cache (saves on every event)"
  return 0
}

self_test() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  local bad_expr="${tmp}/bad-expr.yml"
  cat >"${bad_expr}" <<EOF
name: x
on: push
cache-mode: \${{ github.ref }}
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/julia-depot-cache
EOF
  if ! workflow_cache_verify_all 2>/dev/null; then
    :
  fi
  grep -q 'cache-mode: \${{' "${bad_expr}" || die "self-test: bad-expr fixture broken"
  return 0
}

workflow_cache_verify_all() {
  local fail=0
  check_wrapper_save || fail=1

  for file in "${WORKFLOWS}"/*.yml; do
    [[ -f "${file}" ]] || continue
    local relpath="${file#"${ROOT}/"}"

    while IFS= read -r line; do
      if [[ "${line}" =~ ^cache-mode:.*\$\{\{ ]]; then
        echo "workflow_cache_verify: ${relpath}: cache-mode must be a literal (read/write/…), not \${{ }}" >&2
        fail=1
      fi
    done < <(grep -E '^cache-mode:' "${file}" 2>/dev/null || true)

    if grep -qE '^\s+-\s+uses:\s+julia-actions/cache@' "${file}"; then
      echo "workflow_cache_verify: ${relpath}: use ./.github/actions/julia-depot-cache, not julia-actions/cache" >&2
      fail=1
    fi

    if [[ "${relpath}" == ".github/workflows/CI.yml" ]]; then
      local n
      n="$(grep -cE 'uses:\s+actions/cache/(save|restore)@' "${file}" || true)"
      if (( n != 4 )); then
        echo "workflow_cache_verify: CI.yml: expected 4 JETLS actions/cache steps, found ${n}" >&2
        fail=1
      fi
    elif grep -qE 'uses:\s+actions/cache/(save|restore)@' "${file}" 2>/dev/null; then
      echo "workflow_cache_verify: ${relpath}: actions/cache save/restore belongs in julia-depot-cache or JETLS jobs only" >&2
      fail=1
    fi

    if jetls_hashfiles_in_workflow "${file}"; then
      echo "workflow_cache_verify: ${relpath}: JETLS depot key must not use hashFiles" >&2
      fail=1
    fi
  done

  if grep -q 'Save JETLS depot cache' "${WORKFLOWS}/CI.yml" 2>/dev/null; then
    if ! grep -q "if: github.event_name == 'push' && github.ref == 'refs/heads/main' && steps.jetls-depot-cache.outputs.cache-hit != 'true'" "${WORKFLOWS}/CI.yml"; then
      echo "workflow_cache_verify: CI.yml: JETLS depot save must be push-to-main only" >&2
      fail=1
    fi
  fi

  return "${fail}"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

if ! workflow_cache_verify_all; then
  exit 1
fi
