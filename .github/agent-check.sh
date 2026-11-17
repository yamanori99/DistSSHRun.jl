#!/usr/bin/env bash
# Push gate for Cloud Agents: clean tree, Runic, trailing newlines, whitespace, JETLS, NEWS facts.
#
# Usage:
#   ./.github/agent-check.sh [--base REF] [--help]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNIC_PIN_FILE="${ROOT}/.github/runic-version"

usage() {
  cat <<'EOF'
Usage: ./.github/agent-check.sh [--base REF] [--help]

  --base REF   Diff base (default: merge-base of HEAD and origin/main)
  --help       Print this message and exit 0
EOF
}

die_usage() {
  echo "error: unexpected argument '$1'" >&2
  echo "For more information, try '--help'." >&2
  exit 2
}

BASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --base)
      shift
      [[ $# -gt 0 ]] || die_usage "--base"
      BASE="$1"
      ;;
    --*)
      die_usage "${1#--}"
      ;;
    *)
      die_usage "$1"
      ;;
  esac
  shift
done

if [[ -z "${BASE}" ]]; then
  git -C "${ROOT}" fetch -q origin main
  BASE="$(git -C "${ROOT}" merge-base HEAD origin/main)"
fi

SHA_SHORT="$(git -C "${ROOT}" rev-parse --short HEAD)"
FAILED=()

run_step() {
  local name="$1"
  shift
  if "$@"; then
    return 0
  fi
  FAILED+=("${name}")
  return 0
}

check_clean_tree() {
  local dirty
  dirty="$(git -C "${ROOT}" status --porcelain --untracked-files=all)"
  if [[ -n "${dirty}" ]]; then
    echo "agent-check: working tree not clean (commit or discard changes first)" >&2
    echo "${dirty}" >&2
    return 1
  fi
  return 0
}

check_runic() {
  local want have
  if [[ ! -f "${RUNIC_PIN_FILE}" ]]; then
    echo "agent-check: missing ${RUNIC_PIN_FILE}" >&2
    return 1
  fi
  want="$(tr -d '[:space:]' <"${RUNIC_PIN_FILE}")"
  if ! command -v runic >/dev/null 2>&1; then
    echo "agent-check: runic not on PATH" >&2
    return 1
  fi
  have="$(runic --version 2>/dev/null | sed -n 's/^runic version \([^,]*\).*/\1/p')"
  if [[ "${have}" != "${want}" ]]; then
    echo "agent-check: runic --version ${have} != pin ${want}" >&2
    return 1
  fi
  if ! runic --check --diff .; then
    echo "agent-check: runic --check --diff . failed" >&2
    return 1
  fi
  return 0
}

is_binary_file() {
  local f="$1"
  if git -C "${ROOT}" grep -Iq . -- "${f}" 2>/dev/null; then
    return 1
  fi
  return 0
}

check_trailing_newlines() {
  local f rel ok=0

  while IFS= read -r -d '' rel; do
    [[ -n "${rel}" ]] || continue
    f="${ROOT}/${rel}"
    [[ -f "${f}" ]] || continue
    if is_binary_file "${rel}"; then
      continue
    fi
    if [[ ! -s "${f}" ]]; then
      continue
    fi
    if [[ "$(tail -c 1 "${f}")" != $'\n' ]]; then
      echo "agent-check: ${rel}: file must end with exactly one newline" >&2
      ok=1
      continue
    fi
    if [[ "$(tail -c 2 "${f}" | head -c 1)" == $'\n' ]]; then
      echo "agent-check: ${rel}: file must end with exactly one newline (not two)" >&2
      ok=1
    fi
  done < <(git -C "${ROOT}" diff -z --name-only --diff-filter=ACMR "${BASE}" HEAD)

  [[ "${ok}" -eq 0 ]]
}

check_whitespace() {
  git -C "${ROOT}" diff --check "${BASE}" HEAD
}

check_jetls() {
  "${ROOT}/.github/jetls-check.sh" --progress=none
}

path_needs_fragment() {
  local path="$1"
  case "$path" in
    src/* | ext/*) return 0 ;;
    lib/*)
      case "$path" in
        */src/*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

is_fragment_path() {
  local path="$1" base
  case "$path" in
    changelog.d/*) ;;
    *) return 1 ;;
  esac
  base="${path#changelog.d/}"
  case "$base" in
    */*) return 1 ;;
    *.md) return 0 ;;
    *) return 1 ;;
  esac
}

check_news_facts() {
  local news_fail=0 need=0 frag added path
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if path_needs_fragment "${path}"; then
      need=1
    fi
  done < <(git -C "${ROOT}" diff --name-only "${BASE}" HEAD)

  frag=0
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if is_fragment_path "${path}" && git -C "${ROOT}" diff --name-only --diff-filter=A "${BASE}" HEAD -- "${path}" | grep -q .; then
      frag=1
      added="${path}"
      local first
      first="$(head -n 1 "${ROOT}/${added}")"
      echo "agent-check: NEWS fragment ${added}: ${first}"
      if [[ "${first}" == "category: breaking" ]]; then
        echo "agent-check: -> this PR needs the 'breaking' label. Do not add it yourself; say so in the report."
      fi
    fi
  done < <(git -C "${ROOT}" diff --name-only --diff-filter=A "${BASE}" HEAD)

  if [[ "${need}" -eq 1 && "${frag}" -eq 0 ]]; then
    echo "agent-check: src/lib/src or ext/ changed but no new changelog.d fragment" >&2
    news_fail=1
  fi

  [[ "${news_fail}" -eq 0 ]]
}

run_step "clean tree" check_clean_tree
run_step "runic" check_runic
run_step "trailing newline" check_trailing_newlines
run_step "whitespace" check_whitespace
run_step "jetls" check_jetls
run_step "news" check_news_facts

if ((${#FAILED[@]} > 0)); then
  IFS=,
  echo "agent-check: FAILED on ${SHA_SHORT}: ${FAILED[*]}" >&2
  echo "Fix, commit, and rerun this script from the start. Do not push." >&2
  exit 1
fi

echo "agent-check: all four push-gate checks passed on ${SHA_SHORT}"