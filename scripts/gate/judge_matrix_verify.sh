#!/usr/bin/env bash
# Ensure judge_matrix.sh predicates match CI.yml detect fragments for gated jobs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI="${ROOT}/.github/workflows/CI.yml"

job_if_line() {
  local job="$1"
  awk -v job="${job}" '
    $0 ~ "^  " job ":" { in_job = 1; next }
    in_job && /^  [a-zA-Z0-9_.-]+:/ { exit 1 }
    in_job && /^    if:/ {
      sub(/^    if: /, "")
      sub(/^\$\{\{ /, "")
      sub(/ \}\}$/, "")
      print
      exit
    }
  ' "${CI}"
}

expect_contains() {
  local job="$1"
  local needle="$2"
  local line
  line="$(job_if_line "${job}")" || {
    echo "judge_matrix_verify: missing job ${job}" >&2
    exit 1
  }
  [[ "${line}" == *"${needle}"* ]] || {
    echo "judge_matrix_verify: ${job} if: does not contain: ${needle}" >&2
    echo "  got: ${line}" >&2
    exit 1
  }
}

expect_contains "base-test-ubuntu" "needs.detect.outputs.heavy == 'true' && needs.detect.outputs.base == 'true'"
expect_contains "up-test-ubuntu" "needs.detect.outputs.heavy == 'true' && needs.detect.outputs.up == 'true'"
expect_contains "ship-test-ubuntu" "needs.detect.outputs.heavy == 'true' && needs.detect.outputs.ship == 'true'"
expect_contains "heartbeat-test-ubuntu" "needs.detect.outputs.heavy == 'true' && needs.detect.outputs.heartbeat == 'true'"

expect_contains "up-ssh-e2e" "needs.detect.outputs.e2e == 'true' && (needs.detect.outputs.up == 'true' || needs.detect.outputs.testenv == 'true')"
expect_contains "base-ssh-e2e" "needs.detect.outputs.e2e == 'true' && (needs.detect.outputs.base == 'true' || needs.detect.outputs.testenv == 'true')"
expect_contains "ship-ssh-e2e" "needs.detect.outputs.e2e == 'true' && needs.detect.outputs.ship == 'true'"
expect_contains "heartbeat-ssh-e2e" "needs.detect.outputs.e2e == 'true' && (needs.detect.outputs.heartbeat == 'true' || needs.detect.outputs.testenv == 'true')"
expect_contains "ssh-e2e" "needs.detect.outputs.e2e == 'true' && needs.runic.result == 'success'"
expect_contains "queue-ssh-e2e" "needs.detect.outputs.queue_e2e == 'true' && needs.runic.result == 'success'"

# ship-ssh-e2e must not use testenv OR shortcut
ship_line="$(job_if_line ship-ssh-e2e)"
[[ "${ship_line}" != *"testenv"* ]] || {
  echo "judge_matrix_verify: ship-ssh-e2e must not gate on testenv" >&2
  exit 1
}

echo "ok"