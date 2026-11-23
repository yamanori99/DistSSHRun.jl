#!/usr/bin/env bash
# Self-test skip_unless semantics and downstream gate judge paths used by judge.sh.
set -euo pipefail

pass_scenario() {
  echo "ok  $1"
}

fail_scenario() {
  echo "FAIL  $1" >&2
  exit 1
}

skip_unless() {
  local flag="$1"
  local reason="$2"
  [[ "${flag}" == true ]] && echo "" || echo "${reason}"
}

[[ "$(skip_unless true "detect base=true")" == "" ]] || fail_scenario "skip_unless"
[[ "$(skip_unless false "detect base=true")" == "detect base=true" ]] || fail_scenario "skip_unless"
pass_scenario "skip_unless"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JUDGE="${ROOT}/scripts/gate/judge.sh"

"${ROOT}/scripts/gate/judge_matrix_verify.sh" >/dev/null || fail_scenario "judge_matrix_verify"
pass_scenario "judge_matrix_verify"

"${ROOT}/scripts/gate/workflow_concurrency_verify.sh" --self-test >/dev/null || fail_scenario "workflow_concurrency_self_test"
pass_scenario "workflow_concurrency_self_test"

SKIP_JOBS=(
  test-unit test-integration test-coverage test-macos-unit test-macos-integration test-wsl
  test-1-14-pre-unit test-1-14-pre-integration test-1-14-pre-macos-unit test-1-14-pre-macos-integration
  test-nightly registry-install pkgeval
  base-test-ubuntu base-test-macos base-test-wsl
  up-test-ubuntu up-test-macos up-test-wsl
  ship-test-ubuntu ship-test-macos ship-test-wsl
  heartbeat-test-ubuntu heartbeat-test-macos heartbeat-test-wsl
  up-ssh-e2e base-ssh-e2e ship-ssh-e2e heartbeat-ssh-e2e ssh-e2e ssh-e2e-1-14-pre queue-ssh-e2e
  aqua-1-14-pre aqua-nightly jetls-1-14-pre
)

export_judge_skipped() {
  local id norm
  for id in "${SKIP_JOBS[@]}"; do
    norm="${id//-/_}"
    export "RESULT_${norm}=skipped"
  done
}

export_heavy_pr_core_success() {
  local id norm
  for id in test-unit test-integration test-macos-unit test-macos-integration registry-install \
    test-1-14-pre-unit test-1-14-pre-integration; do
    norm="${id//-/_}"
    export "RESULT_${norm}=success"
  done
  export RESULT_test_coverage=skipped
  export RESULT_test_wsl=skipped
  export RESULT_test_nightly=skipped
  export RESULT_pkgeval=skipped
}

export DETECT_E2E=false
export DETECT_BASE=false
export DETECT_UP=false
export DETECT_SHIP=false
export DETECT_HEARTBEAT=false
export DETECT_TESTENV=false
export DETECT_QUEUE_E2E=false
export DETECT_COVERAGE=false
export RESULT_detect=success
export RESULT_runic=success
export RESULT_diff_lint_self_test=skipped
export RESULT_jetls=success
export RESULT_aqua=success
export RESULT_fix_tests_on_base=skipped
export_judge_skipped

export DETECT_HEAVY=false
export DETECT_SCRIPTS=false
export DETECT_PRECHECK=true
export DETECT_DOWNSTREAM=true
export DETECT_EVENT=schedule
export RESULT_downstream=failure
export RESULT_test_1_14_pre_macos_unit=success
export RESULT_test_1_14_pre_macos_integration=success
out="$("${JUDGE}" 2>&1)" || ec=$?
ec="${ec:-0}"
grep -Fq 'downstream failed (non-blocking report)' <<<"${out}" || fail_scenario "schedule: downstream failure non-blocking"
[[ "${ec}" -eq 0 ]] || fail_scenario "schedule: downstream failure non-blocking"
pass_scenario "schedule: downstream failure non-blocking"

export DETECT_EVENT=pull_request
export DETECT_HEAVY=true
export DETECT_PRECHECK=true
export DETECT_DOWNSTREAM=false
export RESULT_downstream=skipped
export_heavy_pr_core_success
export RESULT_test_1_14_pre_macos_unit=skipped
export RESULT_test_1_14_pre_macos_integration=skipped
out="$("${JUDGE}" 2>&1)" || true
grep -Fq 'allowed skip test-1-14-pre-macos-unit' <<<"${out}" || fail_scenario "pr heavy: macOS 1.14-pre skipped"
pass_scenario "pr heavy: macOS 1.14-pre skipped"

export DETECT_EVENT=pull_request
export DETECT_HEAVY=true
export DETECT_PRECHECK=true
export DETECT_DOWNSTREAM=true
export RESULT_downstream=failure
export_heavy_pr_core_success
if "${JUDGE}" >/dev/null 2>&1; then
  fail_scenario "pr label downstream: downstream runs, failure blocks"
fi
pass_scenario "pr label downstream: downstream runs, failure blocks"

export DETECT_DOWNSTREAM=false
export RESULT_downstream=skipped
export_heavy_pr_core_success
out="$("${JUDGE}" 2>&1)" || true
grep -Fq 'allowed skip downstream' <<<"${out}" || fail_scenario "pr unlabeled: downstream skipped, gate green"
pass_scenario "pr unlabeled: downstream skipped, gate green"

export DETECT_HEAVY=false
export DETECT_PRECHECK=true
export DETECT_DOWNSTREAM=true
export DETECT_EVENT=repository_dispatch
export RESULT_downstream=success
export_judge_skipped
if ! "${JUDGE}" >/dev/null 2>&1; then
  fail_scenario "unknown event: downstream runs"
fi
pass_scenario "unknown event: downstream runs"

export DETECT_FIX_TITLE=false
unset RESULT_fix_tests_on_base
if "${JUDGE}" >/dev/null 2>&1; then
  fail_scenario "missing RESULT_fix_tests_on_base fails gate"
fi
export RESULT_fix_tests_on_base=skipped
pass_scenario "missing RESULT_fix_tests_on_base fails gate"

"${ROOT}/scripts/gate/fix_title_self_test.sh" >/dev/null || fail_scenario "fix_title_self_test"
pass_scenario "fix_title_self_test"

"${ROOT}/scripts/gate/pr-body_gh_self_test.sh" >/dev/null || fail_scenario "pr-body_gh_self_test"
pass_scenario "pr-body_gh_self_test"

chmod +x "${ROOT}/scripts/gate/jetls_log_gate_self_test.sh"
"${ROOT}/scripts/gate/jetls_log_gate_self_test.sh" >/dev/null || fail_scenario "jetls_log_gate_self_test"
pass_scenario "jetls_log_gate_self_test"
