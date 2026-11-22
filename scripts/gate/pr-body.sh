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
  if [[ ! -f "${GATE_PR_BODY_FILE}" || ! -f "${GATE_PR_PATHS_FILE}" ]]; then
    if [[ "${GITHUB_ACTIONS:-}" == "true" && "${GITHUB_EVENT_NAME:-}" != "pull_request" ]]; then
      echo "pr body: skip (not pull_request)"
      exit 0
    fi
    echo "pr body: missing ${GATE_PR_BODY_FILE} or ${GATE_PR_PATHS_FILE}" >&2
    exit 1
  fi
  cp "${GATE_PR_PATHS_FILE}" "${pr_paths}"
  cp "${GATE_PR_BODY_FILE}" "${pr_body}"
elif gh pr view --json body --jq .body >"${pr_body}" 2>"${pr_err}"; then
  git diff --name-only "${diff_range}" >"${pr_paths}"
else
  # shellcheck source=gh-pr-note.sh
  source "${ROOT}/scripts/gate/gh-pr-note.sh"
  set +e
  gh_pr_note_or_continue "${pr_err}"
  _gh_rc=$?
  set -e
  if ((_gh_rc == 2)); then
    echo "pr body: no pull request"
    exit 0
  fi
  if ((_gh_rc == 0)); then
    printf 'note: %s; pr body lint skipped\n' "${gh_pr_note_reason}"
    exit 0
  fi
  cat "${pr_err}" >&2
  echo "pr body: could not read the pull request" >&2
  exit 1
fi

"${ROOT}/scripts/lint/run.sh" pr-body "${pr_paths}" "${pr_body}"
