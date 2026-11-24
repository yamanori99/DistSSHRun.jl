#!/usr/bin/env bash
# Pull requests that touch lint infrastructure need label lint-change-approved.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

die() {
  echo "lint change guard: $*" >&2
  exit 1
}

# One label name per line from the webhook payload (no gh token).
pull_request_labels_from_event() {
  local event_path="${GITHUB_EVENT_PATH:-}"
  local labels=""
  if [[ -z "${event_path}" || ! -r "${event_path}" ]]; then
    die "missing or unreadable GITHUB_EVENT_PATH (${event_path:-unset})"
  fi
  if command -v jq >/dev/null 2>&1; then
    if ! labels="$(
      jq -r '
        if (.pull_request | type) != "object" then
          "pull_request missing\n" | halt_error(1)
        else
          (.pull_request.labels // []) | map(.name) | .[]
        end
      ' "${event_path}" 2>&1
    )"; then
      die "could not parse event payload: ${labels}"
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if ! labels="$(
      python3 - "${event_path}" <<'PY' 2>&1
import json, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
pr = data.get("pull_request")
if not isinstance(pr, dict):
    sys.exit("pull_request missing")
labels = pr.get("labels")
if labels is None:
    labels = []
if not isinstance(labels, list):
    sys.exit("pull_request.labels invalid")
for item in labels:
    if not isinstance(item, dict) or "name" not in item:
        sys.exit("pull_request.labels entry invalid")
    print(str(item["name"]))
PY
    )"; then
      die "could not parse event payload: ${labels}"
    fi
  else
    die "need jq or python3 to read pull_request.labels from the event payload"
  fi
  printf '%s' "${labels}"
}

has_exact_label() {
  local want="$1"
  local labels="$2"
  local label
  while IFS= read -r label || [[ -n "${label}" ]]; do
    [[ "${label}" == "${want}" ]] && return 0
  done <<< "${labels}"
  return 1
}

lint_paths_need_label() {
  local path="$1"
  case "${path}" in
    scripts/lint/* | scripts/check.sh | AGENTS.md | .github/workflows/* | .github/runic/*) return 0 ;;
    scripts/gate/lint_change_guard.sh | scripts/gate/judge.sh | scripts/gate/workflow_gate_wiring_verify.sh) return 0 ;;
    *) return 1 ;;
  esac
}

lint_infra_touched() {
  if [[ "${_LINT_CHANGE_GUARD_TEST_DIFF_FAIL:-}" == 1 ]]; then
    die "could not compare changed paths (mock diff failure)"
  fi
  if [[ "${_LINT_CHANGE_GUARD_SELF_TEST_PATHS:-}" == 1 ]]; then
    return 0
  fi
  local base="${GITHUB_BASE_REF:-main}"
  git fetch --no-tags origin "${base}" 2>/dev/null || true
  local range="origin/${base}...HEAD"
  local paths
  if ! paths="$(git diff --name-only "${range}")"; then
    die "could not compare changed paths (${range})"
  fi
  local p
  while IFS= read -r p || [[ -n "${p}" ]]; do
    [[ -z "${p}" ]] && continue
    lint_paths_need_label "${p}" && return 0
  done <<< "${paths}"
  return 1
}

self_test() {
  local tmp fixture script
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  script="${ROOT}/scripts/gate/lint_change_guard.sh"
  fixture="${ROOT}/scripts/gate/fixtures/lint_change_guard"

  lint_paths_need_label "scripts/lint/diff_lint.jl" || die "self-test: protected lint path"
  lint_paths_need_label "scripts/gate/judge.sh" || die "self-test: protected judge"
  lint_paths_need_label ".github/runic/Project.toml" || die "self-test: protected runic"
  lint_paths_need_label "README.md" && die "self-test: README unprotected"
  lint_paths_need_label "src/DistSSHRun.jl" && die "self-test: src unprotected"

  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${fixture}/event_unlabeled.json" \
    _LINT_CHANGE_GUARD_SELF_TEST_PATHS=1 "${script}" 2>/dev/null && {
    die "self-test: expected exit 1 without label"
  }

  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${fixture}/event_labeled.json" \
    _LINT_CHANGE_GUARD_SELF_TEST_PATHS=1 "${script}" || die "self-test: expected exit 0 with label"

  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${fixture}/event_near_label.json" \
    _LINT_CHANGE_GUARD_SELF_TEST_PATHS=1 "${script}" 2>/dev/null && {
    die "self-test: expected exit 1 for near-miss label name"
  }

  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${fixture}/event_not_a_file" \
    _LINT_CHANGE_GUARD_SELF_TEST_PATHS=1 "${script}" 2>"${tmp}/err" && {
    die "self-test: expected exit 1 for missing event file"
  }
  grep -q 'missing or unreadable GITHUB_EVENT_PATH' "${tmp}/err" || die "self-test: missing path message"

  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${fixture}/event_bad_json.json" \
    _LINT_CHANGE_GUARD_SELF_TEST_PATHS=1 "${script}" 2>"${tmp}/err2" && {
    die "self-test: expected exit 1 for bad json"
  }
  grep -q 'could not parse event payload' "${tmp}/err2" || die "self-test: parse error message"

  GITHUB_EVENT_NAME=pull_request _LINT_CHANGE_GUARD_TEST_DIFF_FAIL=1 \
    GITHUB_EVENT_PATH="${fixture}/event_labeled.json" \
    "${script}" 2>"${tmp}/err3" && die "self-test: expected exit 1 for diff fail"
  grep -q 'could not compare changed paths' "${tmp}/err3" || die "self-test: diff fail message"

  echo "ok  lint_change_guard self-test"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]]; then
  exit 0
fi

lint_infra_touched || exit 0

labels="$(pull_request_labels_from_event)"
if ! has_exact_label "lint-change-approved" "${labels}"; then
  die "touch lint infra without label lint-change-approved"
fi
exit 0