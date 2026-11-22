#!/usr/bin/env bash
# Spot-check downstream gate judge paths (schedule report vs pull_request failure).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
judge="${ROOT}/scripts/gate/judge.sh"

export DETECT_HEAVY=false
export DETECT_SCRIPTS=false
export DETECT_PRECHECK=true
export DETECT_DOWNSTREAM=true
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

skip_jobs=(
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

for id in "${skip_jobs[@]}"; do
  norm="${id//-/_}"
  export "RESULT_${norm}=skipped"
done

export DETECT_EVENT=schedule
export RESULT_downstream=failure
out="$("${judge}" 2>&1)" || ec=$?
ec="${ec:-0}"
grep -Fq 'downstream failed (non-blocking report)' <<<"${out}" || {
  echo "judge_downstream_self_test: expected non-blocking note on schedule (exit=${ec})" >&2
  printf '%s\n' "${out}" >&2
  exit 1
}
[[ "${ec}" -eq 0 ]] || {
  echo "judge_downstream_self_test: schedule judge must succeed (exit=${ec})" >&2
  exit 1
}

export DETECT_EVENT=pull_request
export DETECT_HEAVY=true
export DETECT_PRECHECK=true
export RESULT_downstream=failure
for id in test-unit test-integration test-macos-unit test-macos-integration registry-install \
  test-1-14-pre-unit test-1-14-pre-integration test-1-14-pre-macos-unit test-1-14-pre-macos-integration; do
  norm="${id//-/_}"
  export "RESULT_${norm}=success"
done
export RESULT_test_coverage=skipped
export RESULT_test_wsl=skipped
export RESULT_test_nightly=skipped
export RESULT_pkgeval=skipped
if "${judge}" >/dev/null 2>&1; then
  echo "judge_downstream_self_test: expected failure on pull_request" >&2
  exit 1
fi

export DETECT_DOWNSTREAM=false
export RESULT_downstream=skipped
export DETECT_EVENT=pull_request
export DETECT_HEAVY=true
export DETECT_PRECHECK=true
for id in test-unit test-integration test-macos-unit test-macos-integration registry-install \
  test-1-14-pre-unit test-1-14-pre-integration test-1-14-pre-macos-unit test-1-14-pre-macos-integration; do
  norm="${id//-/_}"
  export "RESULT_${norm}=success"
done
export RESULT_test_coverage=skipped
export RESULT_test_wsl=skipped
export RESULT_test_nightly=skipped
export RESULT_pkgeval=skipped
out="$("${judge}" 2>&1)" || true
grep -Fq 'allowed skip downstream' <<<"${out}" || {
  echo "judge_downstream_self_test: expected allowed skip without label" >&2
  printf '%s\n' "${out}" >&2
  exit 1
}

echo "ok"