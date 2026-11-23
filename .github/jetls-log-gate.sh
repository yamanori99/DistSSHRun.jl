#!/usr/bin/env bash
# Fail closed when jetls logged a Pkg precompile failure but still exited 0.
# Usage: jetls-log-gate.sh LOG_FILE
set -euo pipefail

log="${1:?log file required}"

if grep -q 'failed to precompile' "${log}"; then
    _line="$(grep -m 1 'failed to precompile' "${log}")"
    {
        echo "jetls-check: a package failed to precompile during environment setup."
        echo "jetls-check: matched line: ${_line}"
    } >&2
    exit 1
fi