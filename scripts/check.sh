#!/usr/bin/env bash
# Local push gate. Same pins as CI. Does not install tools.
#
#   ./scripts/check.sh
#   ./scripts/check.sh --verbose
#
# Default: one ok/FAIL line per step; subprocess output only on failure.
# --verbose: legacy ---- check: ... ---- banners and streamed output.
# On success prints `HEAD <sha>: passed` (optional total seconds).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
# shellcheck source=section.sh
source "${ROOT}/scripts/section.sh"
# shellcheck source=julia.sh
source "${ROOT}/scripts/julia.sh"

die() {
  echo "check: $*" >&2
  exit 1
}

CHECK_VERBOSE=0
for arg in "$@"; do
  case "${arg}" in
    --verbose) CHECK_VERBOSE=1 ;;
    -h | --help)
      echo "usage: ./scripts/check.sh [--verbose]" >&2
      exit 0
      ;;
    *)
      die "unknown argument: ${arg}"
      ;;
  esac
done
export CHECK_VERBOSE
export CHECK_GATE_QUIET=$((CHECK_VERBOSE ? 0 : 1))

# A linked worktree's .git is a file. hooksPath may point outside the repo.
git_path() {
  local p hooks
  hooks="$(git config --path --get core.hooksPath 2>/dev/null || true)"
  if [[ "$1" == hooks/* && -n "${hooks}" ]]; then
    p="${hooks}/${1#hooks/}"
  else
    p="$(git rev-parse --git-path "$1")"
  fi
  if [[ "${p}" != /* ]]; then
    p="${ROOT}/${p}"
  fi
  printf '%s\n' "${p}"
}

install_pre_push() {
  local src="${ROOT}/scripts/pre-push.sh"
  local dest
  [[ -f "${src}" ]] || return 0
  dest="$(git_path hooks/pre-push)"
  mkdir -p "$(dirname "${dest}")"
  if [[ -e "${dest}" ]] && ! grep -q 'distsshrun-check-gate' "${dest}"; then
    echo "check: pre-push hook exists and is not the gate. Left it in place." >&2
    return 0
  fi
  cp "${src}" "${dest}"
  chmod +x "${dest}"
}
install_pre_push

RUNIC_COMPAT="${ROOT}/.github/runic/Project.toml"
JETLS_ACTION="${ROOT}/.github/actions/jetls-check/action.yml"

pin_help() {
  echo "check: pin: $1" >&2
  echo "check: do not install unless the person asked" >&2
  exit 1
}

if [[ -n "$(git status --porcelain)" ]]; then
  die "git status is not empty. Commit first, then rerun ./scripts/check.sh on that commit."
fi

gate_sha="$(git rev-parse HEAD)"
stamp_path="$(git_path check-gate-ok)"
rm -f "${stamp_path}"
GATE_T0=$SECONDS
export GATE_DIFF_BASE="${GATE_DIFF_BASE:-origin/main}"
export GATE_DIFF_HEAD="${GATE_DIFF_HEAD:-HEAD}"

# macOS and Linux, including WSL2, use this same gate.
# Native Windows is not a supported environment.
case "$(uname -s)" in
  Darwin | Linux) ;;
  MINGW* | MSYS* | CYGWIN*)
    die "native Windows is not supported. Use WSL2 Ubuntu. This gate then uses the Linux conditions."
    ;;
  *)
    die "unsupported OS $(uname -s). Supported environments are macOS and Linux, including WSL2 Ubuntu."
    ;;
esac

if [[ "${CHECK_VERBOSE}" == 1 ]]; then
  section "check: pins"
fi
_pins_start=$SECONDS
use_julia_1_13 || pin_help "Julia 1.13 is not on PATH"
depot="$("${JULIA[@]}" --startup-file=no -e 'print(DEPOT_PATH[1])')"

runic_pin="$(sed -n -E 's/^Runic = "=([^"]+)".*/\1/p' "${RUNIC_COMPAT}" | head -1)"
if [[ ! "${runic_pin}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pin_help "Runic compat pin missing in .github/runic/Project.toml"
fi

jetls_pin="$(grep -E -m 1 -o 'rev="[0-9]{4}-[0-9]{2}-[0-9]{2}"' "${JETLS_ACTION}" || true)"
jetls_pin="${jetls_pin#rev=\"}"
jetls_pin="${jetls_pin%\"}"
if [[ ! "${jetls_pin}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  pin_help "JETLS date pin missing in .github/actions/jetls-check/action.yml"
fi

runic_bin="${depot}/bin/runic"
jetls_bin="${depot}/bin/jetls"
jetls_manifest="${depot}/environments/apps/JETLS/Manifest.toml"

if [[ ! -x "${runic_bin}" ]]; then
  pin_help "Runic ${runic_pin} app is missing (${runic_bin})"
fi
runic_ver="$(JULIA_APPS_JULIA_CMD="${JULIA_BIN}" "${runic_bin}" --version 2>/dev/null | sed -n 's/^runic version \([^,]*\).*/\1/p' || true)"
if [[ "${runic_ver}" != "${runic_pin}" ]]; then
  pin_help "Runic app is ${runic_ver:-unknown}, pin is ${runic_pin}"
fi
same_file() {
  if ! command -v realpath >/dev/null 2>&1; then
    pin_help "realpath is missing, so the pin cannot be compared"
  fi
  [[ "$(realpath "$1")" == "$(realpath "$2")" ]]
}

if command -v runic >/dev/null 2>&1; then
  path_runic="$(command -v runic)"
  if ! same_file "${path_runic}" "${runic_bin}"; then
    pin_help "PATH runic is ${path_runic}, not the pin ${runic_pin}"
  fi
fi

if [[ ! -x "${jetls_bin}" ]]; then
  pin_help "JETLS ${jetls_pin} app is missing (${jetls_bin})"
fi
jetls_got=""
if [[ -f "${jetls_manifest}" ]]; then
  jetls_got="$(awk '
    /^\[\[deps\.JETLS\]\]/ { in_jetls = 1; next }
    /^\[\[deps\./ { if (in_jetls) exit }
    in_jetls && /^repo-rev = / {
      line = $0
      sub(/^repo-rev = /, "", line)
      gsub(/"/, "", line)
      print line
      exit
    }
  ' "${jetls_manifest}")"
fi
if [[ "${jetls_got}" != "${jetls_pin}" ]]; then
  pin_help "JETLS app rev is ${jetls_got:-missing}, pin is ${jetls_pin}"
fi
if command -v jetls >/dev/null 2>&1; then
  path_jetls="$(command -v jetls)"
  if ! same_file "${path_jetls}" "${jetls_bin}"; then
    pin_help "PATH jetls is ${path_jetls}, not the pin ${jetls_pin}"
  fi
fi
root_ver="$(sed -n -E 's/^version = "([^"]+)"/\1/p' "${ROOT}/Project.toml" | head -1)"
while IFS= read -r proj; do
  [[ -n "${proj}" ]] || continue
  src_err="$(
    awk -v rootver="${root_ver}" -v file="${proj}" '
      BEGIN { ver = rootver }
      /^version = / {
        line = $0
        sub(/^version = "/, "", line)
        sub(/".*/, "", line)
        ver = line
      }
      /^\[sources\]/ { src = 1; next }
      /^\[/ { src = 0 }
      src && /rev[[:space:]]*=/ {
        rev = $0
        sub(/^[^=]*=[[:space:]]*"?/, "", rev)
        sub(/".*/, "", rev)
        sub(/[[:space:]].*/, "", rev)
        if (rev != "main") {
          printf "%s: [sources] rev is %s, not main\n", file, rev
          bad = 1
        } else if (ver !~ /-DEV/) {
          printf "%s: [sources] rev = \"main\" requires a -DEV version (got %s)\n", file, ver
          bad = 1
        }
      }
      END { if (bad) exit 1 }
    ' "${ROOT}/${proj}"
  )" || true
  if [[ -n "${src_err}" ]]; then
    die "${src_err}"
  fi
done < <(git ls-files '*Project.toml')
gate_ok "pins" "(Runic ${runic_pin}, JETLS ${jetls_pin})" "$((SECONDS - _pins_start))"

gate_env_example() {
  local os_name arch jver want_julia=0
  case "$(uname -s)" in
    Darwin) os_name="macOS $(sw_vers -productVersion 2>/dev/null || echo unknown)" ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        os_name="WSL2 Linux"
      else
        os_name="Linux"
      fi
      ;;
    *) os_name="$(uname -s)" ;;
  esac
  arch="$(uname -m)"
  if [[ -f "${pr_paths:-}" ]] && grep -q '\.jl$' "${pr_paths}"; then
    want_julia=1
  fi
  jver=""
  if [[ "${want_julia}" == 1 && -n "${JULIA_BIN:-}" && -x "${JULIA_BIN}" ]]; then
    jver="$("${JULIA_BIN}" --startup-file=no -e 'print(VERSION)' 2>/dev/null || true)"
  fi
  if [[ -n "${jver}" ]]; then
    printf '%s %s, Julia %s' "${os_name}" "${arch}" "${jver}"
  else
    printf '%s %s' "${os_name}" "${arch}"
  fi
}

pr_description_time() {
  local url owner name num when
  url="$(gh pr view --json url --jq .url 2>/dev/null)" || return 0
  [[ "${url}" =~ ^https://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+)$ ]] || return 0
  owner="${BASH_REMATCH[1]}"
  name="${BASH_REMATCH[2]}"
  num="${BASH_REMATCH[3]}"
  when="$(
    gh api graphql \
      -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){lastEditedAt createdAt}}}' \
      -f o="${owner}" -f r="${name}" -F n="${num}" \
      --jq '.data.repository.pullRequest | .lastEditedAt // .createdAt' 2>/dev/null || true
  )"
  printf '%s' "${when}"
}

pr_body_print_hints() {
  local body_file="$1"
  local env_ex committed edited
  env_ex="$(gate_env_example)"
  committed="$(git log -1 --format=%cI)"
  edited="$(pr_description_time)"
  while IFS= read -r hint; do
    [[ -z "${hint}" ]] && continue
    if [[ "${hint}" == note:* ]]; then
      printf '%s\n' "${hint}"
    else
      gate_note "pr body: ${hint}"
    fi
  done < <(CHECK_HEAD="${gate_sha}" "${ROOT}/scripts/lint/run.sh" pr-body-hints "${body_file}" "${env_ex}" "${committed}" "${edited}")
}

_pr_start=$SECONDS
pr_paths="$(mktemp)"
pr_body="$(mktemp)"
pr_err="$(mktemp)"
pr_log="$(mktemp)"
cleanup_pr() {
  rm -f "${pr_paths}" "${pr_body}" "${pr_err}" "${pr_log}"
}
trap cleanup_pr EXIT
git diff --name-only origin/main...HEAD >"${pr_paths}"
if gh pr view --json body --jq .body >"${pr_body}" 2>"${pr_err}"; then
  if [[ "${CHECK_VERBOSE}" == 1 ]]; then
    section "check: pr body"
    "${ROOT}/scripts/lint/run.sh" pr-body "${pr_paths}" "${pr_body}"
    section "check: pr body ok"
    pr_body_print_hints "${pr_body}"
  else
    set +e
    "${ROOT}/scripts/lint/run.sh" pr-body "${pr_paths}" "${pr_body}" >"${pr_log}" 2>&1
    pr_rc=$?
    set -e
    if ((pr_rc != 0)); then
      gate_fail_show "pr body" "${pr_log}" "${pr_rc}"
    fi
    gate_ok "pr body" "" "$((SECONDS - _pr_start))"
    pr_body_print_hints "${pr_body}"
  fi
else
  # shellcheck source=gate/gh-pr-note.sh
  source "${ROOT}/scripts/gate/gh-pr-note.sh"
  set +e
  gh_pr_note_or_continue "${pr_err}"
  _gh_rc=$?
  set -e
  if ((_gh_rc == 2)); then
    if [[ "${CHECK_VERBOSE}" == 1 ]]; then
      echo "check: pr body: no pull request"
      section "check: pr body ok"
    else
      gate_ok "pr body" "(no pull request)" "$((SECONDS - _pr_start))"
    fi
  elif ((_gh_rc == 0)); then
    if [[ "${CHECK_VERBOSE}" == 1 ]]; then
      printf 'note: %s; pr body lint skipped\n' "${gh_pr_note_reason}"
      section "check: pr body ok"
    else
      gate_ok "pr body" "(note: ${gh_pr_note_reason})" "$((SECONDS - _pr_start))"
    fi
  else
    cat "${pr_err}" >&2
    die "pr body: could not read the pull request"
  fi
fi

gate_capture "runic ${runic_pin}" env JULIA_APPS_JULIA_CMD="${JULIA_BIN}" "${runic_bin}" --check --diff .

_ws_start=$SECONDS
export GATE_DIFF_BASE="origin/main"
export GATE_DIFF_HEAD="HEAD"
export GATE_NEWLINE_ALL="${GATE_NEWLINE_ALL:-0}"
if [[ "${CHECK_VERBOSE}" == 1 ]]; then
  env GATE_DIFF_BASE="${GATE_DIFF_BASE}" GATE_DIFF_HEAD="${GATE_DIFF_HEAD}" \
    GATE_NEWLINE_ALL="${GATE_NEWLINE_ALL}" "${ROOT}/scripts/gate/whitespace.sh"
  section "check: whitespace ok"
else
  if ! env GATE_DIFF_BASE="${GATE_DIFF_BASE}" GATE_DIFF_HEAD="${GATE_DIFF_HEAD}" \
    GATE_NEWLINE_ALL="${GATE_NEWLINE_ALL}" "${ROOT}/scripts/gate/whitespace.sh" >/dev/null 2>&1; then
    _ws_log="$(mktemp)"
    env GATE_DIFF_BASE="${GATE_DIFF_BASE}" GATE_DIFF_HEAD="${GATE_DIFF_HEAD}" \
      GATE_NEWLINE_ALL="${GATE_NEWLINE_ALL}" "${ROOT}/scripts/gate/whitespace.sh" >"${_ws_log}" 2>&1 || true
    gate_fail_show "whitespace" "${_ws_log}" 1
  fi
  gate_ok "whitespace" "" "$((SECONDS - _ws_start))"
fi

gate_capture "jetls ${jetls_pin}" env JULIA_APPS_JULIA_CMD="${JULIA_BIN}" "${ROOT}/.github/jetls-check.sh" --progress=none

_lint_start=$SECONDS
if [[ "${CHECK_VERBOSE}" == 1 ]]; then
  env GATE_DIFF_BASE="${GATE_DIFF_BASE}" GATE_DIFF_HEAD="${GATE_DIFF_HEAD}" "${ROOT}/scripts/gate/lint.sh"
  section "check: lint ok"
else
  gate_capture "lint" env GATE_DIFF_BASE="${GATE_DIFF_BASE}" GATE_DIFF_HEAD="${GATE_DIFF_HEAD}" \
    "${ROOT}/scripts/gate/lint.sh"
fi

gate_capture "shellcheck" "${ROOT}/scripts/gate/shellcheck.sh"
gate_capture "gitleaks" "${ROOT}/scripts/gate/gitleaks.sh"

gate_capture "removed names" "${ROOT}/scripts/lint/run.sh" removed-names

INVARIANT_NAMES=()
if ((${#INVARIANT_NAMES[@]} > 0)); then
  for _inv in "${INVARIANT_NAMES[@]}"; do
    if ! git grep -q -F "@testset \"invariant: ${_inv}\"" -- test; then
      die "missing @testset \"invariant: ${_inv}\""
    fi
  done
fi

if ! git merge-tree --write-tree origin/main HEAD >/dev/null 2>&1; then
  die "branch conflicts with origin/main"
fi
_behind="$(git rev-list --count HEAD..origin/main)"
_mb="$(git merge-base HEAD origin/main)"
_age="$(($(git log -1 --format=%ct origin/main) - $(git log -1 --format=%ct "${_mb}")))"
if ((_behind > 40)) || ((_age > 48 * 3600)); then
  printf 'note: branch is stale versus origin/main (%s commits, %ss)\n' "${_behind}" "${_age}"
  _pr_err="$(mktemp)"
  if _labels="$(gh pr view --json labels --jq '[.labels[].name] | join(",")' 2>"${_pr_err}")"; then
    rm -f "${_pr_err}"
    if [[ ",${_labels}," == *",cut,"* ]]; then
      die "stale branch with cut label"
    fi
  else
    # shellcheck source=gate/gh-pr-note.sh
    source "${ROOT}/scripts/gate/gh-pr-note.sh"
    set +e
    gh_pr_note_or_continue "${_pr_err}"
    _gh_rc=$?
    set -e
    if ((_gh_rc == 2)); then
      rm -f "${_pr_err}"
    elif ((_gh_rc == 0)); then
      rm -f "${_pr_err}"
      printf 'note: %s; stale-branch label check skipped\n' "${gh_pr_note_reason}"
    else
      cat "${_pr_err}" >&2
      rm -f "${_pr_err}"
      die "stale branch: could not read pull request labels"
    fi
  fi
fi

if git diff --name-only origin/main...HEAD | grep -qE '^\.github/(workflows/|actions/julia-depot-cache/)'; then
  gate_capture "workflow cache" "${ROOT}/scripts/gate/workflow_cache_verify.sh"
  gate_capture "workflow concurrency" "${ROOT}/scripts/gate/workflow_concurrency_verify.sh"
  if command -v actionlint >/dev/null 2>&1; then
    gate_capture "actionlint" actionlint -ignore 'unexpected key "queue" for "concurrency"'
  else
    printf 'note: actionlint not found; workflows unchecked locally, CI will check\n'
  fi
  if command -v zizmor >/dev/null 2>&1; then
    gate_capture "zizmor" zizmor --offline --no-progress .github
  else
    printf 'note: zizmor not found; workflows unchecked locally, CI will check\n'
  fi
  if command -v pinact >/dev/null 2>&1; then
    gate_capture "pinact" pinact run --fix=false --no-api
  else
    printf 'note: pinact not found; workflows unchecked locally, CI will check\n'
  fi
fi

gate_capture "docs static" "${ROOT}/scripts/docs.sh" static
gate_capture "docs maybe" "${ROOT}/scripts/docs.sh" maybe

if [[ -n "$(git status --porcelain)" ]]; then
  die "git status is not empty. Commit first, then rerun ./scripts/check.sh on that commit."
fi
head_now="$(git rev-parse HEAD)"
if [[ "${head_now}" != "${gate_sha}" ]]; then
  die "HEAD moved during the gate (${gate_sha} -> ${head_now}). Rerun ./scripts/check.sh on ${head_now}."
fi
printf '%s\n' "${gate_sha}" >"${stamp_path}"
_total=$((SECONDS - GATE_T0))
if (( _total >= 3 )); then
  echo "HEAD ${gate_sha}: passed (${_total}s)"
else
  echo "HEAD ${gate_sha}: passed"
fi
