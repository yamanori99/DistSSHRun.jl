#!/usr/bin/env bash
# Sourced by the gate scripts. shellcheck SC2148 wants a shebang on this file.

# CHECK_VERBOSE=1: stream subprocess output and use legacy ---- banners.
# CHECK_GATE_QUIET=1: suppress section() banners (default for check.sh).

section() {
  if [[ "${CHECK_VERBOSE:-0}" == 1 ]]; then
    printf '%s\n' "---- $* ----"
  fi
}

_gate_fmt_secs() {
  local elapsed="${1:-0}"
  if [[ "${elapsed}" =~ ^[0-9]+$ ]] && (( elapsed >= 3 )); then
    printf ' %ds' "${elapsed}"
  fi
}

_gate_pending() {
  [[ "${CHECK_VERBOSE:-0}" == 1 ]] && return 0
  [[ -t 1 ]] || return 0
  printf '..    %s\n' "$1"
}

gate_note() {
  printf 'note  %s\n' "$1"
}

gate_ok() {
  local label="$1"
  local detail="${2:-}"
  local elapsed="${3:-0}"
  local suffix
  suffix="$(_gate_fmt_secs "${elapsed}")"
  if [[ -n "${detail}" ]]; then
    printf 'ok    %s %s%s\n' "${label}" "${detail}" "${suffix}"
  else
    printf 'ok    %s%s\n' "${label}" "${suffix}"
  fi
}

gate_fail_show() {
  local label="$1"
  local log="$2"
  local rc="${3:-1}"
  printf 'FAIL  %s\n' "${label}" >&2
  printf '%s\n' "----- ${label} output -----" >&2
  cat "${log}" >&2
  printf '%s\n' '-----' >&2
  local sha
  sha="$(git rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "${sha}" ]]; then
    echo "HEAD ${sha}: failed at ${label}" >&2
  fi
  rm -f "${log}"
  exit "${rc}"
}

# Run a command; on success one ok line, on failure dump log and exit.
gate_capture() {
  local label="$1"
  shift
  local start=$SECONDS
  local log
  log="$(mktemp)"
  _gate_pending "${label}"
  set +e
  "$@" >"${log}" 2>&1
  local rc=$?
  set -e
  local elapsed=$((SECONDS - start))
  if (( rc != 0 )); then
    gate_fail_show "${label}" "${log}" "${rc}"
  fi
  if [[ "${CHECK_VERBOSE:-0}" == 1 ]]; then
    cat "${log}"
  fi
  local detail=""
  if grep -q 'make\.jl skipped' "${log}"; then
    detail="(make.jl skipped)"
  elif grep -q 'pr body: no pull request' "${log}"; then
    detail="(no pull request)"
  fi
  rm -f "${log}"
  gate_ok "${label}" "${detail}" "${elapsed}"
}
