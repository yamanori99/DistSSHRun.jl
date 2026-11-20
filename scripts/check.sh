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
gate_ok "pins" "(Runic ${runic_pin}, JETLS ${jetls_pin})" "$((SECONDS - _pins_start))"

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
  else
    set +e
    "${ROOT}/scripts/lint/run.sh" pr-body "${pr_paths}" "${pr_body}" >"${pr_log}" 2>&1
    pr_rc=$?
    set -e
    if ((pr_rc != 0)); then
      gate_fail_show "pr body" "${pr_log}" "${pr_rc}"
    fi
    gate_ok "pr body" "" "$((SECONDS - _pr_start))"
  fi
elif grep -q 'no pull requests found' "${pr_err}"; then
  if [[ "${CHECK_VERBOSE}" == 1 ]]; then
    echo "check: pr body: no pull request"
    section "check: pr body ok"
  else
    gate_ok "pr body" "(no pull request)" "$((SECONDS - _pr_start))"
  fi
else
  cat "${pr_err}" >&2
  die "pr body: could not read the pull request"
fi

gate_capture "runic ${runic_pin}" env JULIA_APPS_JULIA_CMD="${JULIA_BIN}" "${runic_bin}" --check --diff .

_ws_start=$SECONDS
if [[ "${CHECK_VERBOSE}" == 1 ]]; then
  section "check: whitespace"
fi
while IFS= read -r -d '' f; do
  [[ -f "${f}" ]] || continue
  numstat="$(git diff --numstat origin/main...HEAD -- "${f}")"
  if [[ "${numstat}" == -* ]]; then
    continue
  fi
  if [[ ! -s "${f}" ]]; then
    continue
  fi
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
done < <(git diff --name-only -z origin/main...HEAD)

git diff --check origin/main...HEAD
if [[ "${CHECK_VERBOSE}" == 1 ]]; then
  section "check: whitespace ok"
else
  gate_ok "whitespace" "" "$((SECONDS - _ws_start))"
fi

gate_capture "jetls ${jetls_pin}" env JULIA_APPS_JULIA_CMD="${JULIA_BIN}" "${ROOT}/.github/jetls-check.sh" --progress=none

lint_names=(banned-words agents-md skip-reasons new-comments stdlib-compat ssh-argv aqua-run)
_lint_start=$SECONDS
_lint_log="$(mktemp)"
_lint_fail=""
for lint in "${lint_names[@]}"; do
  script="${ROOT}/scripts/lint/${lint}.sh"
  if [[ ! -x "${script}" ]]; then
    die "missing ${script#"${ROOT}/"}"
  fi
  if [[ "${CHECK_VERBOSE}" == 1 ]]; then
    section "check: lint ${lint}"
    "${script}"
    section "check: lint ${lint} ok"
  else
    if ! "${script}" >>"${_lint_log}" 2>&1; then
      _lint_fail="${lint}"
      break
    fi
  fi
done
if [[ "${CHECK_VERBOSE}" != 1 ]]; then
  if [[ -n "${_lint_fail}" ]]; then
    gate_fail_show "lint ${_lint_fail}" "${_lint_log}" 1
  fi
  rm -f "${_lint_log}"
  gate_ok "lint" "(${#lint_names[@]} modes)" "$((SECONDS - _lint_start))"
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
