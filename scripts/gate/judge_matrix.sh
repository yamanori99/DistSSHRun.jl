#!/usr/bin/env bash
# Detect-side predicates for judge.sh. Keep in sync with .github/workflows/CI.yml job `if:` lines.
# Verified by judge_matrix_verify.sh (run from judge_self_test.sh and diff_lint self-test).
set -euo pipefail

pkg_should_run() {
  local flag="$1"
  [[ "${heavy:-false}" == true && "${flag}" == true ]]
}

e2e_up_should_run() {
  [[ "${e2e:-false}" == true && ( "${up:-false}" == true || "${testenv:-false}" == true ) ]]
}

e2e_base_should_run() {
  [[ "${e2e:-false}" == true && ( "${base:-false}" == true || "${testenv:-false}" == true ) ]]
}

e2e_ship_should_run() {
  [[ "${e2e:-false}" == true && "${ship:-false}" == true ]]
}

e2e_heartbeat_should_run() {
  [[ "${e2e:-false}" == true && ( "${heartbeat:-false}" == true || "${testenv:-false}" == true ) ]]
}

e2e_run_should_run() {
  [[ "${e2e:-false}" == true ]]
}

queue_e2e_should_run() {
  [[ "${queue_e2e:-false}" == true ]]
}

prereq_gate_jobs_ok() {
  [[ "$(result_of runic)" == success && "$(result_of jetls)" == success && "$(result_of aqua)" == success ]]
}

# Mirror GitHub skip when detect predicate is false or runic/jetls/aqua blocked the job.
judge_when_detect() {
  local id="$1"
  local should_run="$2"
  local detect_off="$3"
  local r
  r="$(result_of "${id}")"
  case "${r}" in
    success)
      if [[ "${should_run}" == true ]]; then
        judge "${id}" ""
      else
        fail "${id} succeeded but detect predicate was false"
      fi
      ;;
    skipped)
      if [[ "${should_run}" != true ]]; then
        judge "${id}" "${detect_off}"
      elif ! prereq_gate_jobs_ok; then
        judge "${id}" "runic/jetls/aqua prerequisite"
      else
        fail "${id} skipped unexpectedly"
      fi
      ;;
    *)
      if [[ "${should_run}" == true ]]; then
        judge "${id}" ""
      else
        judge "${id}" "${detect_off}"
      fi
      ;;
  esac
}