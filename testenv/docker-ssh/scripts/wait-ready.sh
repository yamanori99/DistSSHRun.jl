#!/usr/bin/env bash
# Wait until both docker-ssh workers accept BatchMode SSH and have Julia.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH_CONFIG="${ROOT}/.generated/ssh_config"
KNOWN_HOSTS="${ROOT}/.generated/known_hosts"
HOSTS=(child-1 child-2)
MAX_ATTEMPTS="${DISTSSH_SSH_WAIT_ATTEMPTS:-60}"
SLEEP_SEC="${DISTSSH_SSH_WAIT_SLEEP:-2}"

if [[ ! -f "${SSH_CONFIG}" ]]; then
  echo "missing ${SSH_CONFIG}; run scripts/gen-keys.sh first" >&2
  exit 1
fi

# Workers get new host keys every create. Stale IPs in known_hosts fail
# BatchMode (`Host key verification failed`) while sshd is already up.
: > "${KNOWN_HOSTS}"
chmod 600 "${KNOWN_HOSTS}"

ssh_ok() {
  local host="$1"
  ssh -F "${SSH_CONFIG}" -o ConnectTimeout=5 "${host}" 'echo ok' >/dev/null 2>&1
}

julia_ok() {
  local host="$1"
  ssh -F "${SSH_CONFIG}" -o ConnectTimeout=5 "${host}" \
    'test -x /usr/local/bin/julia && /usr/local/bin/julia --version' >/dev/null 2>&1
}

no_rsync_ok() {
  local host="$1"
  if ssh -F "${SSH_CONFIG}" -o ConnectTimeout=5 "${host}" \
    'command -v rsync >/dev/null 2>&1'; then
    echo "SSH E2E worker must not have rsync; transfers must not depend on it (${host})" >&2
    return 1
  fi
}

for host in "${HOSTS[@]}"; do
  echo "Waiting for SSH on ${host}..."
  ok=0
  for ((i = 1; i <= MAX_ATTEMPTS; i++)); do
    if ssh_ok "${host}"; then
      ok=1
      break
    fi
    sleep "${SLEEP_SEC}"
  done
  if [[ "${ok}" -ne 1 ]]; then
    echo "SSH not ready: ${host}" >&2
    ssh -F "${SSH_CONFIG}" -o ConnectTimeout=5 "${host}" 'echo ok' >&2 || true
    exit 1
  fi
  if ! julia_ok "${host}"; then
    echo "Julia not ready on ${host}" >&2
    exit 1
  fi
  if ! no_rsync_ok "${host}"; then
    exit 1
  fi
  echo "  ${host}: ok"
done
