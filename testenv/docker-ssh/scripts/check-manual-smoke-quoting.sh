#!/usr/bin/env bash
# Regression checks for write-kit-env.sh and prepare-manual-remote-root.sh quoting.
# No workers required for the local cases. Optional live SSH when ssh_config works.
#
#   ./scripts/check-manual-smoke-quoting.sh
#   ./scripts/check-manual-smoke-quoting.sh --live
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="${ROOT}/scripts"
LIVE=0
for arg in "$@"; do
  case "${arg}" in
    --live) LIVE=1 ;;
    -h|--help)
      echo "usage: $0 [--live]"
      exit 0
      ;;
    *)
      echo "unknown arg: ${arg}" >&2
      exit 2
      ;;
  esac
done

_posix_sq() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

fail=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; fail=1; }

# --- write-kit-env: source + shell parse under awkward absolute paths ----------
check_write_kit_env() {
  local label=$1 base=$2
  local env_file ssh_config
  mkdir -p "${base}/.generated" "${base}/scripts"
  ssh_config="${base}/.generated/ssh_config"
  : >"${ssh_config}"
  cp "${SCRIPT_DIR}/write-kit-env.sh" "${base}/scripts/write-kit-env.sh"
  "${base}/scripts/write-kit-env.sh"
  env_file="${base}/.generated/env.sh"
  [[ -f "${env_file}" ]] || { fail "${label}: missing env.sh"; return; }

  unset DISTRIBUTED_SSH_OPTS GIT_SSH_COMMAND
  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a

  local got_f=""
  # shellcheck disable=SC2086
  eval "set -- ${GIT_SSH_COMMAND}"
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-F" ]]; then
      got_f="${2:-}"
      break
    fi
    shift
  done
  if [[ "${got_f}" == "${ssh_config}" ]]; then
    pass "${label}: GIT_SSH_COMMAND -F path"
  else
    fail "${label}: GIT_SSH_COMMAND -F got=${got_f} want=${ssh_config}"
  fi

  if command -v julia >/dev/null 2>&1; then
    local jl
    jl="$(
      WANT_CFG="${ssh_config}" DISTRIBUTED_SSH_OPTS="${DISTRIBUTED_SSH_OPTS}" \
        julia --startup-file=no -e '
          opts = String[String(x) for x in Base.shell_split(ENV["DISTRIBUTED_SSH_OPTS"])]
          want = ENV["WANT_CFG"]
          println(opts == ["-F", want, "-o", "RequestTTY=no"] ? "OK" : "BAD $(repr(opts))")
        '
    )"
    if [[ "${jl}" == "OK" ]]; then
      pass "${label}: Base.shell_split DISTRIBUTED_SSH_OPTS"
    else
      fail "${label}: Base.shell_split ${jl}"
    fi
  else
    echo "SKIP: julia not on PATH for shell_split (${label})"
  fi
}

TMP=$(mktemp -d /tmp/dsr-smoke-quote-XXXXXX)
trap 'rm -rf "${TMP}"' EXIT

check_write_kit_env "ordinary path" "${TMP}/ordinary/docker-ssh"
check_write_kit_env "space in path" "${TMP}/gen space/docker-ssh"
check_write_kit_env "apostrophe in path" "${TMP}/cfg's/docker-ssh"
check_write_kit_env "dollar metachar path" "${TMP}/cfg\$HOME/docker-ssh"
check_write_kit_env "semicolon path" "${TMP}/semi;rm/docker-ssh"
check_write_kit_env "backtick path" "${TMP}/back\`id\`/docker-ssh"

# --- prepare-manual-remote-root: local HOME stands in for remote shell --------
check_remote_word() {
  local label=$1 parent=$2 repo=$3
  local home word mode
  home=$(mktemp -d "${TMP}/home-XXXXXX")
  word="~/$(_posix_sq "${parent}/${repo}")"
  if ! env HOME="${home}" bash -lc "mkdir -p -m 755 ${word} && chmod go-w ${word}"; then
    fail "${label}: mkdir remote_word=${word}"
    return
  fi
  if [[ -d "${home}/${parent}/${repo}" ]]; then
    mode="$(stat -f '%Lp' "${home}/${parent}/${repo}" 2>/dev/null || stat -c '%a' "${home}/${parent}/${repo}")"
    if [[ "${mode}" == "755" ]]; then
      pass "${label}: dir mode 755"
    else
      fail "${label}: mode=${mode} want=755"
    fi
  else
    fail "${label}: missing ${home}/${parent}/${repo}"
  fi
  if [[ -e "${home}/pwned" || -e /tmp/pwned-dsr-smoke ]]; then
    fail "${label}: injection sentinel exists"
  else
    pass "${label}: no shell injection"
  fi
}

check_remote_word "ordinary remote_root" "GitHub" "DistSSHRun.jl"
check_remote_word "space remote_root" "Git Hub" "DistSSHRun.jl"
check_remote_word "apostrophe remote_root" "GitHub" "DistSSHRun's.jl"
check_remote_word "dollar remote_root" 'foo$(touch pwned)' "bar"
check_remote_word "backtick remote_root" 'foo`touch /tmp/pwned-dsr-smoke`' "bar"
check_remote_word "semicolon remote_root" "foo;touch-pwned" "bar"

# Unquoted space must not create the intended Parent/Repo path
unquoted_home=$(mktemp -d "${TMP}/home-bad-XXXXXX")
unquoted_parent="Git Hub"
unquoted_repo="DistSSHRun.jl"
env HOME="${unquoted_home}" bash -lc "mkdir -p -m 755 ~/${unquoted_parent}/${unquoted_repo}" >/dev/null 2>&1 || true
if [[ -d "${unquoted_home}/Git Hub/${unquoted_repo}" ]]; then
  fail "unquoted space unexpectedly created intended dir"
elif [[ -d "${unquoted_home}/Git" ]]; then
  pass "unquoted space splits (control: wrong dir Git/)"
else
  pass "unquoted space does not create intended path"
fi

# --- live workers: ordinary prepare + env source ------------------------------
if [[ "${LIVE}" -eq 1 ]]; then
  CFG="${ROOT}/.generated/ssh_config"
  if [[ ! -f "${CFG}" ]]; then
    fail "live: missing ${CFG}"
  else
    "${SCRIPT_DIR}/prepare-manual-remote-root.sh"
    "${SCRIPT_DIR}/write-kit-env.sh"
    unset DISTRIBUTED_SSH_OPTS GIT_SSH_COMMAND
    set -a
    # shellcheck disable=SC1090
    source "${ROOT}/.generated/env.sh"
    set +a
    kit_root="$(cd "${ROOT}/../.." && pwd)"
    parent="$(basename "$(dirname "${kit_root}")")"
    repo="$(basename "${kit_root}")"
    for host in child-1 child-2; do
      mode="$(
        ssh -F "${CFG}" "${host}" \
          "stat -c '%a' ~/${parent}/${repo}"
      )"
      if [[ "${mode}" == "755" ]]; then
        pass "live ${host}: ~/${parent}/${repo} mode 755"
      else
        fail "live ${host}: mode=${mode}"
      fi
    done
    if "${SCRIPT_DIR}/with-env.sh" bash -c 'test -n "${DISTRIBUTED_SSH_OPTS:-}" && test -n "${GIT_SSH_COMMAND:-}"'; then
      pass "live: with-env provides DISTRIBUTED_SSH_OPTS and GIT_SSH_COMMAND"
    else
      fail "live: with-env missing env"
    fi
  fi
else
  echo "SKIP: live workers (pass --live)"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "check-manual-smoke-quoting: FAILED" >&2
  exit 1
fi
echo "check-manual-smoke-quoting: OK"
