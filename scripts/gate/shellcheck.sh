#!/usr/bin/env bash
# shellcheck over tracked *.sh under scripts/, .github/, testenv/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck: not on PATH" >&2
  exit 1
fi

shopt -s globstar nullglob
mapfile -t files < <(
  git ls-files 'scripts/**/*.sh' '.github/**/*.sh' 'testenv/**/*.sh' | LC_ALL=C sort
)
if ((${#files[@]} == 0)); then
  echo "shellcheck: no tracked shell scripts" >&2
  exit 1
fi

fail=0
for f in "${files[@]}"; do
  [[ -f "${f}" ]] || continue
  if ! shellcheck -x "${f}"; then
    fail=1
  fi
done
exit "${fail}"