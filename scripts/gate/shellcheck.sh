#!/usr/bin/env bash
# Run ShellCheck on tracked shell scripts under scripts/, .github/, and testenv/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck: not on PATH" >&2
  exit 1
fi

files=()
while IFS= read -r f; do
  [[ -n "${f}" ]] || continue
  files+=("${f}")
done < <(
  {
    git ls-files 'scripts/*.sh' 'scripts/**/*.sh' '.github/*.sh' '.github/**/*.sh' 'testenv/**/*.sh'
  } | LC_ALL=C sort -u
)
if ((${#files[@]} == 0)); then
  echo "shellcheck: no tracked shell scripts" >&2
  exit 1
fi

fail=0
for f in "${files[@]}"; do
  [[ -f "${f}" ]] || continue
  if ! shellcheck -x -S error "${f}"; then
    fail=1
  fi
done
exit "${fail}"
