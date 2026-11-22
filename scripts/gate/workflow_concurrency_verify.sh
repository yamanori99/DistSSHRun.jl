#!/usr/bin/env bash
# Workflows whose concurrency group uses github.event.pull_request.number need a
# fallback when a non-pull_request trigger can fire (push, schedule, etc.).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOWS="${ROOT}/.github/workflows"

die() {
  echo "workflow_concurrency_verify: $*" >&2
  exit 1
}

# Event keys under `on:` that do not populate pull_request.number.
NON_PR_TRIGGERS='push|schedule|workflow_dispatch|repository_dispatch|workflow_call|registry_package|release|create|delete|issues|issue_comment|discussion|discussion_comment|fork|watch|public|pull_request_review|pull_request_review_comment|pull_request_comment|status|check_run|check_suite|deployment|deployment_status|page_build|workflow_run|label|milestone|member|membership|meta|package|gollum|team_add|project|project_card|project_column|star|security_advisory'

on_triggers() {
  local file="$1"
  awk '
    /^on:/ { in_on = 1; next }
    in_on && /^[^ #]/ { exit }
    in_on && /^  [a-zA-Z0-9_.-]+:/ {
      key = $1
      sub(/:$/, "", key)
      print key
    }
  ' "${file}"
}

has_non_pr_trigger() {
  local file="$1"
  local key
  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    case "${key}" in
      pull_request | pull_request_target) ;;
      *) return 0 ;;
    esac
  done < <(on_triggers "${file}")
  return 1
}

concurrency_groups() {
  local file="$1"
  awk '
    /^concurrency:/ { in_c = 1; next }
    in_c && /^[^ ]/ { in_c = 0 }
    in_c && /^  group:/ {
      line = $0
      sub(/^  group: */, "", line)
      print line
    }
    /^    concurrency:/ { in_job_c = 1; next }
    in_job_c && /^      group:/ {
      line = $0
      sub(/^      group: */, "", line)
      print line
    }
    in_job_c && /^    [a-zA-Z]/ && !/^    concurrency:/ { in_job_c = 0 }
  ' "${file}"
}

uses_pr_number_without_fallback() {
  local group="$1"
  [[ "${group}" == *'pull_request.number'* ]] || return 1
  [[ "${group}" == *'pull_request.number ||'* ]] && return 1
  [[ "${group}" == *'pull_request.number||'* ]] && return 1
  return 0
}

verify_file() {
  local file="$1"
  local relpath="${file#"${ROOT}/"}"
  [[ "${relpath}" == "${file}" ]] && relpath="${file}"
  has_non_pr_trigger "${file}" || return 0
  local group
  while IFS= read -r group; do
    [[ -z "${group}" ]] && continue
    if uses_pr_number_without_fallback "${group}"; then
      echo "workflow_concurrency_verify: ${relpath}: concurrency group uses pull_request.number without a fallback but the workflow has non-PR triggers: ${group}" >&2
      return 1
    fi
  done < <(concurrency_groups "${file}")
}

run_self_test() {
  local tmp err rc
  tmp="$(mktemp -d)"
  err="${tmp}/err"
  trap 'rm -rf "${tmp}"' RETURN

  cat >"${tmp}/good-pr-only.yml" <<'EOF'
name: Good PR only
on:
  pull_request:
concurrency:
  group: x-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: true
EOF

  cat >"${tmp}/good-fallback.yml" <<'EOF'
name: Good fallback
on:
  pull_request_target:
  push:
    branches: [main]
concurrency:
  group: x-${{ github.event.pull_request.number || github.sha }}
  cancel-in-progress: true
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: true
EOF

  cat >"${tmp}/bad-push.yml" <<'EOF'
name: Bad push
on:
  pull_request_target:
  push:
    branches: [main]
concurrency:
  group: x-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: true
EOF

  verify_file "${tmp}/good-pr-only.yml"
  verify_file "${tmp}/good-fallback.yml"
  if verify_file "${tmp}/bad-push.yml" 2>"${err}"; then
    die "self-test: expected bad-push.yml to fail"
  fi
  grep -q 'without a fallback' "${err}" || die "self-test: unexpected error: $(cat "${err}")"
  echo "ok"
}

main() {
  local f
  shopt -s nullglob
  for f in "${WORKFLOWS}"/*.yml; do
    verify_file "${f}" || exit 1
  done
  echo "ok"
}

if [[ "${1:-}" == --self-test ]]; then
  run_self_test
else
  main
fi
