#!/usr/bin/env bash
# Trailing-newline audit and git diff --check. Shared by check.sh and CI gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
# shellcheck source=../section.sh
source "${ROOT}/scripts/section.sh"

die() {
  echo "whitespace: $*" >&2
  exit 1
}

GATE_DIFF_BASE="${GATE_DIFF_BASE:-origin/main}"
GATE_DIFF_HEAD="${GATE_DIFF_HEAD:-HEAD}"
GATE_NEWLINE_ALL="${GATE_NEWLINE_ALL:-0}"
diff_range="${GATE_DIFF_BASE}...${GATE_DIFF_HEAD}"

audit_file() {
  local f="$1"
  [[ -f "${f}" ]] || return 0
  [[ -s "${f}" ]] || return 0
  case "${f}" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.woff|*.woff2) return 0 ;;
  esac
  local last
  last="$(tail -c 1 "${f}" | od -An -tu1 | tr -d '[:space:]')"
  if [[ "${last}" != "10" ]]; then
    die "${f} does not end with exactly one newline"
  fi
  if [[ "$(tail -c 2 "${f}" | wc -c | tr -d '[:space:]')" -eq 2 ]]; then
  prev="$(tail -c 2 "${f}" | od -An -tu1 | tr -d '[:space:]')"
    if [[ "${prev}" == "1010" ]]; then
      die "${f} ends with more than one newline"
    fi
  fi
}

if [[ "${CHECK_VERBOSE:-0}" == 1 ]]; then
  section "check: whitespace"
fi

if [[ "${GATE_NEWLINE_ALL}" == 1 ]]; then
  while IFS= read -r -d '' f; do
    audit_file "${f}"
  done < <(git ls-files -z)
else
  while IFS= read -r -d '' f; do
    numstat="$(git diff --numstat "${diff_range}" -- "${f}")"
    if [[ "${numstat}" == -* ]]; then
      continue
    fi
    audit_file "${f}"
  done < <(git diff --name-only -z "${diff_range}")
fi

git diff --check "${diff_range}"
