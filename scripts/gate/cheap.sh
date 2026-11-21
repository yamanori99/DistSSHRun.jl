#!/usr/bin/env bash
# Cheap mechanical guards shared by ./scripts/check.sh and the CI `gate` job.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
# shellcheck source=../section.sh
source "${ROOT}/scripts/section.sh"
# shellcheck source=../julia.sh
source "${ROOT}/scripts/julia.sh"

GATE_DIFF_BASE="${GATE_DIFF_BASE:-origin/main}"
GATE_DIFF_HEAD="${GATE_DIFF_HEAD:-HEAD}"
export GATE_DIFF_BASE GATE_DIFF_HEAD

run_step() {
  local label="$1"
  shift
  if [[ "${CHECK_VERBOSE:-0}" == 1 ]]; then
    section "check: ${label}"
    "$@"
    section "check: ${label} ok"
  else
    gate_capture "${label}" "$@"
  fi
}

use_julia_1_13 || exit 1
depot="$("${JULIA[@]}" --startup-file=no -e 'print(DEPOT_PATH[1])')"
RUNIC_COMPAT="${ROOT}/.github/runic/Project.toml"
runic_pin="$(sed -n -E 's/^Runic = "=([^"]+)".*/\1/p' "${RUNIC_COMPAT}" | head -1)"
runic_bin="${depot}/bin/runic"
[[ -x "${runic_bin}" ]] || {
  echo "cheap: Runic app missing (${runic_bin})" >&2
  exit 1
}

run_step "runic ${runic_pin}" env JULIA_APPS_JULIA_CMD="${JULIA_BIN}" "${runic_bin}" --check --diff .

run_step "whitespace" env GATE_DIFF_BASE="${GATE_DIFF_BASE}" GATE_DIFF_HEAD="${GATE_DIFF_HEAD}" \
  GATE_NEWLINE_ALL="${GATE_NEWLINE_ALL:-0}" "${ROOT}/scripts/gate/whitespace.sh"

run_step "lint" env GATE_DIFF_BASE="${GATE_DIFF_BASE}" GATE_DIFF_HEAD="${GATE_DIFF_HEAD}" \
  "${ROOT}/scripts/gate/lint.sh"

run_step "shellcheck" "${ROOT}/scripts/gate/shellcheck.sh"

run_step "pr body" env GATE_DIFF_BASE="${GATE_DIFF_BASE}" GATE_DIFF_HEAD="${GATE_DIFF_HEAD}" \
  GATE_PR_BODY_FILE="${GATE_PR_BODY_FILE:-}" GATE_PR_PATHS_FILE="${GATE_PR_PATHS_FILE:-}" \
  "${ROOT}/scripts/gate/pr-body.sh"