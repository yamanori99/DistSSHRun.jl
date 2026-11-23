#!/usr/bin/env bash
# Self-test .github/jetls-log-gate.sh precompile detection.
set -euo pipefail

fail() {
    echo "jetls_log_gate_self_test: $*" >&2
    exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="${ROOT}/.github/jetls-log-gate.sh"

[[ -x "${GATE}" ]] || fail "missing executable ${GATE}"

_log="$(mktemp)"
cleanup() { rm -f "${_log}"; }
trap cleanup EXIT

echo "ok output" >"${_log}"
"${GATE}" "${_log}" || fail "clean log must pass"

echo "The following 1 package failed to precompile: CompileBench" >"${_log}"
if "${GATE}" "${_log}" >/dev/null 2>&1; then
    fail "precompile line must fail closed"
fi

echo "ok"