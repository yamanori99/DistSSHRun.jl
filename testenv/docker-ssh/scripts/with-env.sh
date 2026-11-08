#!/usr/bin/env bash
# Run a command with docker-ssh / apple-container DistSSHRun SSH env.
# Does not export into the parent shell (source + exec in this process only).
#
#   ./scripts/with-env.sh julia --project=. -m DistSSHRun up status parent child:child-1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT}/.generated/env.sh"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "missing ${ENV_FILE}; run testenv/docker-ssh/scripts/up.sh or testenv/apple-container-ssh/scripts/up.sh" >&2
  exit 1
fi

if [[ "$#" -eq 0 ]]; then
  echo "usage: $0 COMMAND [ARGS...]" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
exec "$@"
