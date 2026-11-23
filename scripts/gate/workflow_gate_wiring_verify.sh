#!/usr/bin/env bash
# CI.yml gate job must need every job, pass RESULT_* into judge, and judge must cover each job.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI="${ROOT}/.github/workflows/CI.yml"
ALLOWLIST="${ROOT}/scripts/gate/ci_gate_wiring_allowlist.txt"
JUDGE="${ROOT}/scripts/gate/judge.sh"

die() {
  echo "workflow_gate_wiring_verify: $*" >&2
  exit 1
}

read_allowlist() {
  ALLOWED=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="$(echo "${line}" | tr -d '[:space:]')"
    [[ -n "${line}" ]] || continue
    ALLOWED+=("${line}")
  done <"${ALLOWLIST}"
}

list_ci_jobs() {
  awk '
    /^jobs:/ { in_jobs = 1; next }
    in_jobs && /^[^ #]/ && $0 !~ /^  / { exit }
    in_jobs && /^  [a-zA-Z0-9_.-]+:/ {
      sub(/^  /, "")
      sub(/:.*/, "")
      print
    }
  ' "${CI}"
}

list_gate_needs() {
  awk '
    /^  gate:/ { in_gate = 1; next }
    in_gate && /^  [a-zA-Z0-9_.-]+:/ && $0 !~ /^    / { exit }
    in_gate && /^    needs:/ { in_needs = 1; next }
    in_gate && in_needs {
      if ($0 ~ /^      - /) {
        sub(/^      - /, "")
        print
      } else if ($0 ~ /^    [a-zA-Z]/ && $0 !~ /^      /) {
        in_needs = 0
      }
    }
  ' "${CI}"
}

list_result_env() {
  awk '
    /^      - name: Judge required jobs/ { in_judge = 1; next }
    in_judge && /^        run:.*judge\.sh/ { exit }
    in_judge && /^          RESULT_/ {
      line = $0
      sub(/^          /, "")
      sub(/:.*/, "")
      sub(/^RESULT_/, "")
      gsub(/_/, "-")
      print
    }
  ' "${CI}"
}

judge_id_for_job() {
  local job="$1"
  case "${job}" in
    diff-lint-self-test) echo "diff_lint_self_test" ;;
    fix-tests-on-base) echo "fix_tests_on_base" ;;
    *) echo "${job}" ;;
  esac
}

judge_handles_job() {
  local job="$1"
  local judge_id fail=1
  judge_id="$(judge_id_for_job "${job}")"
  if grep -qE "(^|[[:space:]])judge[[:space:]]+${judge_id}([[:space:]]|\"|\$)" "${JUDGE}"; then
    return 0
  fi
  if grep -qE "judge_when_detect[[:space:]]+${job}[[:space:]]" "${JUDGE}"; then
    return 0
  fi
  if grep -qE "judge_macos_1_14_pre[[:space:]]+${job}" "${JUDGE}"; then
    return 0
  fi
  if [[ "${job}" == "downstream" ]] && grep -q 'judge_downstream' "${JUDGE}"; then
    return 0
  fi
  if grep -qE "for id in .*${job}" "${JUDGE}"; then
    return 0
  fi
  return 1
}

verify_all() {
  local fail=0 job
  local -a jobs needs results
  jobs=()
  needs=()
  results=()
  read_allowlist
  while IFS= read -r line; do
    [[ -n "${line}" ]] && jobs+=("${line}")
  done < <(list_ci_jobs)
  while IFS= read -r line; do
    [[ -n "${line}" ]] && needs+=("${line}")
  done < <(list_gate_needs)
  while IFS= read -r line; do
    [[ -n "${line}" ]] && results+=("${line}")
  done < <(list_result_env)

  is_allowed() {
    local id="$1" a
    for a in "${ALLOWED[@]}"; do
      [[ "${a}" == "${id}" ]] && return 0
    done
    return 1
  }

  in_list() {
    local needle="$1"
    shift
    local x
    for x in "$@"; do
      [[ "${x}" == "${needle}" ]] && return 0
    done
    return 1
  }

  for job in "${jobs[@]}"; do
    is_allowed "${job}" && continue
    in_list "${job}" "${needs[@]}" || {
      echo "workflow_gate_wiring_verify: gate.needs missing job ${job}" >&2
      fail=1
    }
  done

  for job in "${needs[@]}"; do
    in_list "${job}" "${jobs[@]}" || {
      echo "workflow_gate_wiring_verify: gate.needs lists unknown job ${job}" >&2
      fail=1
    }
    is_allowed "${job}" && continue
    in_list "${job}" "${results[@]}" || {
      echo "workflow_gate_wiring_verify: gate Judge step missing RESULT_${job//-/_}" >&2
      fail=1
    }
    judge_handles_job "${job}" || {
      echo "workflow_gate_wiring_verify: judge.sh does not handle ${job}" >&2
      fail=1
    }
  done

  return "${fail}"
}

self_test() {
  local tmp fail
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  cat >"${tmp}/allow.txt" <<'EOF'
gate
notify
extra
EOF
  ALLOWLIST="${tmp}/allow.txt"
  read_allowlist
  [[ "${#ALLOWED[@]}" -eq 3 ]] || die "self-test: allowlist parse"
  CI_SAVE="${CI}"
  CI="${tmp}/CI.yml"
  cat >"${CI}" <<'EOF'
jobs:
  detect:
    steps: []
  gate:
    needs:
      - detect
    steps:
      - name: Judge required jobs
        env:
          RESULT_detect: x
        run: ./scripts/gate/judge.sh
EOF
  jobs=()
  needs=()
  results=()
  while IFS= read -r line; do jobs+=("${line}"); done < <(list_ci_jobs)
  [[ "${jobs[0]}" == "detect" && "${jobs[1]}" == "gate" ]] || die "self-test: job list"
  while IFS= read -r line; do needs+=("${line}"); done < <(list_gate_needs)
  [[ "${needs[0]}" == "detect" ]] || die "self-test: needs"
  while IFS= read -r line; do results+=("${line}"); done < <(list_result_env)
  [[ "${results[0]}" == "detect" ]] || die "self-test: results"
  CI="${CI_SAVE}"
  ALLOWLIST="${ROOT}/scripts/gate/ci_gate_wiring_allowlist.txt"
  echo "ok  workflow_gate_wiring_verify self-test"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

[[ -f "${CI}" ]] || die "missing ${CI}"
[[ -f "${JUDGE}" ]] || die "missing ${JUDGE}"
[[ -f "${ALLOWLIST}" ]] || die "missing allowlist"

if ! verify_all; then
  exit 1
fi
