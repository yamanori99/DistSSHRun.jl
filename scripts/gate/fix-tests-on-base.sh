#!/usr/bin/env bash
# Run on pull requests whose title starts with fix: or fix( (Conventional Commits).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

BASE="${BASE:?BASE must name the pull request base commit}"

git fetch --no-tags origin "${BASE}"
files=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && files+=("${line}")
done < <(git diff --name-only "${BASE}"...HEAD -- 'test/**/*.jl' 'lib/*/test/**/*.jl' | grep -v '/e2e.jl$' || true)
if [ "${#files[@]}" -eq 0 ]; then
  echo "no added or changed test files (e2e.jl is not run here)" >&2
  exit 1
fi
julia --project=. --startup-file=no -e 'using Pkg; Pkg.instantiate()'
failed=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  if ! julia --project=. --startup-file=no "$f"; then
    failed=1
  fi
done
if [ "$failed" -ne 0 ]; then
  echo "selected tests failed on pull request source" >&2
  exit 1
fi
git checkout "${BASE}" -- src lib/DistSSHBase/src lib/DistSSHUp/src lib/DistSSHShip/src lib/DistSSHHeartbeat/src
failed=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  if ! julia --project=. --startup-file=no "$f"; then
    failed=1
  fi
done
if [ "$failed" -eq 0 ]; then
  echo "new tests also passed on merge-base src" >&2
  exit 1
fi
