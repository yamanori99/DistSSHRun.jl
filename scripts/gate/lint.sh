#!/usr/bin/env bash
# All diff lint modes (+ self-test when scripts/lint/ changed, + runtests inventory).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

GATE_DIFF_BASE="${GATE_DIFF_BASE:-origin/main}"
GATE_DIFF_HEAD="${GATE_DIFF_HEAD:-HEAD}"
export GATE_DIFF_RANGE="${GATE_DIFF_BASE}...${GATE_DIFF_HEAD}"

"${ROOT}/scripts/lint/run.sh" all

if git diff --name-only "${GATE_DIFF_RANGE}" | grep -q '^scripts/lint/'; then
  env -u GATE_DIFF_RANGE GATE_DIFF_BASE= GATE_DIFF_HEAD= \
    "${ROOT}/scripts/lint/run.sh" self-test
  bogus="d56a722ee521eda73e7df5c7bc0b186e9407ab1a...3963089a57e73146e0411104b4be53f4e8847dd8"
  GATE_DIFF_RANGE="${bogus}" "${ROOT}/scripts/lint/run.sh" self-test >/dev/null || {
    echo "lint: self-test must ignore bogus GATE_DIFF_RANGE (run.sh clears it)" >&2
    exit 1
  }
fi
