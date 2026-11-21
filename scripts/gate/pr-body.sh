#!/usr/bin/env bash
# PR body lint. Local: gh pr view. CI: GATE_PR_BODY_FILE / GATE_PR_PATHS_FILE.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
# shellcheck source=../section.sh
source "${ROOT}/scripts/section.sh"

GATE_DIFF_BASE="${GATE_DIFF_BASE:-origin/main}"
GATE_DIFF_HEAD="${GATE_DIFF_HEAD:-HEAD}"
diff_range="${GATE_DIFF_BASE}...${GATE_DIFF_HEAD}"

pr_paths="$(mktemp)"
pr_body="$(mktemp)"
pr_err="$(mktemp)"
cleanup() {
  rm -f "${pr_paths}" "${pr_body}" "${pr_err}"
}
trap cleanup EXIT

if [[ -n "${GATE_PR_PATHS_FILE:-}" && -n "${GATE_PR_BODY_FILE:-}" ]]; then
  cp "${GATE_PR_PATHS_FILE}" "${pr_paths}"
  cp "${GATE_PR_BODY_FILE}" "${pr_body}"
elif gh pr view --json body --jq .body >"${pr_body}" 2>"${pr_err}"; then
  git diff --name-only "${diff_range}" >"${pr_paths}"
elif grep -q 'no pull requests found' "${pr_err}"; then
  echo "pr body: no pull request"
  exit 0
else
  cat "${pr_err}" >&2
  echo "pr body: could not read the pull request" >&2
  exit 1
fi

"${ROOT}/scripts/lint/run.sh" pr-body "${pr_paths}" "${pr_body}"