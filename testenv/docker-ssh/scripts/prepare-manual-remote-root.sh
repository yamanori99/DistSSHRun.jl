#!/usr/bin/env bash
# Create the DistSSHRun default remote_root on child-1 / child-2 for manual smoke.
#
# Matches DistSSHBase.default_remote_project_path: ~/Parent/RepoName from kit root.
# Mode 755 + go-w (ship refuses group/world writable). Same idea as E2E
# `_ssh_e2e_ensure_remote_root!`. Does not change product behavior.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT_ROOT="$(cd "${ROOT}/../.." && pwd)"
CFG="${ROOT}/.generated/ssh_config"

if [[ ! -f "${CFG}" ]]; then
  echo "missing ${CFG}; run up.sh first" >&2
  exit 1
fi

parent="$(basename "$(dirname "${KIT_ROOT}")")"
repo="$(basename "${KIT_ROOT}")"
remote_root="~/${parent}/${repo}"

for host in child-1 child-2; do
  # Tilde expands on the remote (User=dev → /home/dev/…).
  ssh -F "${CFG}" "${host}" \
    "mkdir -p -m 755 ${remote_root} && chmod go-w ${remote_root}"
done

echo "Manual smoke remote_root ready: ${remote_root} (child-1, child-2)"
