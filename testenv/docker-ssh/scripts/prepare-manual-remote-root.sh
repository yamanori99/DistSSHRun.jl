#!/usr/bin/env bash
# Create the DistSSHRun default remote_root on child-1 / child-2 for manual smoke.
#
# Matches DistSSHBase.default_remote_project_path: ~/Parent/RepoName from kit root.
# Mode 755 + go-w (ship refuses group/world writable). Same idea as E2E
# `_ssh_e2e_ensure_remote_root!`. Does not change product behavior.
#
# Leaves `~/` bare so the remote login shell expands home; POSIX-quotes the
# Parent/RepoName rest so spaces and metacharacters stay path data (same shape
# as DistSSHBase._remote_shell_path_word).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT_ROOT="$(cd "${ROOT}/../.." && pwd)"
CFG="${ROOT}/.generated/ssh_config"

if [[ ! -f "${CFG}" ]]; then
  echo "missing ${CFG}; run up.sh first" >&2
  exit 1
fi

# POSIX single-quote one word (same idea as DistSSHBase.posix_quote).
_posix_sq() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

parent="$(basename "$(dirname "${KIT_ROOT}")")"
repo="$(basename "${KIT_ROOT}")"
# Display form (unquoted); remote command uses quoted rest after ~/.
remote_root="~/${parent}/${repo}"
remote_word="~/$(_posix_sq "${parent}/${repo}")"

for host in child-1 child-2; do
  # Tilde expands on the remote (User=dev → /home/dev/…).
  ssh -F "${CFG}" "${host}" \
    "mkdir -p -m 755 ${remote_word} && chmod go-w ${remote_word}"
done

echo "Manual smoke remote_root ready: ${remote_root} (child-1, child-2)"
