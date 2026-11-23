#!/usr/bin/env bash
# Pull requests that touch lint infrastructure need label lint-change-approved.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]]; then
  exit 0
fi

base="${GITHUB_BASE_REF:-main}"
git fetch --no-tags origin "${base}" 2>/dev/null || true
range="origin/${base}...HEAD"
paths="$(git diff --name-only "${range}" || true)"
if ! printf '%s\n' "${paths}" | grep -qE '^(scripts/lint/|scripts/check\.sh|AGENTS\.md|\.github/workflows/)'; then
  if ! printf '%s\n' "${paths}" | grep -q 'scripts/lint/diff_lint\.jl'; then
    exit 0
  fi
fi

labels=""
if command -v gh >/dev/null 2>&1; then
  labels="$(gh pr view --json labels --jq '[.labels[].name] | join(" ")' 2>/dev/null || true)"
fi
if [[ " ${labels} " != *" lint-change-approved "* ]]; then
  echo "lint change guard: touch lint infra without label lint-change-approved" >&2
  exit 1
fi
exit 0