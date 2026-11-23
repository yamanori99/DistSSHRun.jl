#!/usr/bin/env bash
# Bash 3.2 (macOS default) must run scripts under scripts/, .github/, and testenv/apple-container-ssh/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

die() {
  echo "bash32_compat_verify: $*" >&2
  exit 1
}

# Scope: paths contributors run on macOS or macOS CI — scripts/, .github/, testenv/apple-container-ssh/.
list_scope_files() {
  {
    git ls-files 'scripts/*.sh' 'scripts/**/*.sh'
    git ls-files '.github/*.sh' '.github/**/*.sh'
    git ls-files 'testenv/apple-container-ssh/*.sh' 'testenv/apple-container-ssh/**/*.sh'
  } | LC_ALL=C sort -u | grep -v 'scripts/gate/bash32_compat_verify\.sh$' || true
}

# Bash 4+ tokens to flag (mechanical; no parser).
bash4_patterns() {
  local file="$1" relpath line n fail=0
  relpath="${file#"${ROOT}/"}"
  n=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    if [[ "${line}" =~ (^|[^[:alnum:]_])mapfile([^[:alnum:]_]|$) ]]; then
      echo "bash32_compat_verify: ${relpath}:${n}: mapfile (Bash 4+)" >&2
      fail=1
    fi
    if [[ "${line}" =~ (^|[^[:alnum:]_])readarray([^[:alnum:]_]|$) ]]; then
      echo "bash32_compat_verify: ${relpath}:${n}: readarray (Bash 4+)" >&2
      fail=1
    fi
    if [[ "${line}" =~ \$\{[^}]*,,|\^\^ ]]; then
      echo "bash32_compat_verify: ${relpath}:${n}: \${var,,}/\${var^^} (Bash 4+)" >&2
      fail=1
    fi
    if [[ "${line}" =~ declare[[:space:]]+-A ]]; then
      echo "bash32_compat_verify: ${relpath}:${n}: declare -A (Bash 4+)" >&2
      fail=1
    fi
    if [[ "${line}" == *'&>>'* ]]; then
      echo "bash32_compat_verify: ${relpath}:${n}: &>> (Bash 4+)" >&2
      fail=1
    fi
    if [[ "${line}" == *'|&'* ]]; then
      echo "bash32_compat_verify: ${relpath}:${n}: |& (Bash 4+)" >&2
      fail=1
    fi
    if [[ "${line}" == *'@Q}'* ]]; then
      echo "bash32_compat_verify: ${relpath}:${n}: \${var@Q} (Bash 4+)" >&2
      fail=1
    fi
    if [[ "${line}" =~ coproc ]]; then
      echo "bash32_compat_verify: ${relpath}:${n}: coproc (Bash 4+)" >&2
      fail=1
    fi
  done <"${file}"
  return "${fail}"
}

verify_all() {
  local fail=0 f
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    [[ -f "${f}" ]] || continue
    bash4_patterns "${f}" || fail=1
  done < <(list_scope_files)
  return "${fail}"
}

self_test() {
  local tmp good bad
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  good="${tmp}/ok.sh"
  bad="${tmp}/bad.sh"
  printf '%s\n' '#!/bin/bash' 'echo ok' >"${good}"
  printf '%s\n' '#!/bin/bash' 'mapfile -t x < file' >"${bad}"
  bash4_patterns "${good}" || die "self-test: good fixture"
  if bash4_patterns "${bad}" 2>/dev/null; then
    die "self-test: bad fixture should fail"
  fi
  echo "ok  bash32_compat_verify self-test"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

if ! verify_all; then
  exit 1
fi
