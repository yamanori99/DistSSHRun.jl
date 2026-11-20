#!/usr/bin/env bash
# distsshrun-check-gate
# Installed into .git/hooks/pre-push by scripts/check.sh.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "${root}"
sha="$(git rev-parse HEAD)"
while read -r _local_ref local_sha _remote_ref _remote_sha; do
  [[ -n "${local_sha}" ]] || continue
  [[ "${local_sha}" =~ ^0+$ ]] && continue
  if [[ "${local_sha}" != "${sha}" ]]; then
    echo "pre-push: ${local_sha} is not HEAD ${sha}. Run ./scripts/check.sh on that commit." >&2
    exit 1
  fi
done
stamp="$(git rev-parse --git-path check-gate-ok)"
if [[ "${stamp}" != /* ]]; then
  stamp="${root}/${stamp}"
fi
if [[ -f "${stamp}" ]] && [[ "$(cat "${stamp}")" == "${sha}" ]]; then
  echo "ok    check (already passed ${sha})"
  exit 0
fi
exec ./scripts/check.sh
