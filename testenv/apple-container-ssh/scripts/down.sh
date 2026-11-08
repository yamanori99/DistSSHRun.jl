#!/usr/bin/env bash
# Stop and remove Apple-container SSH children (leave buildkit alone).
set -euo pipefail

if ! command -v container >/dev/null 2>&1; then
  echo "container CLI not found (Apple container)" >&2
  exit 1
fi

DOCKER_ROOT="$(cd "$(dirname "$0")/../../docker-ssh" && pwd)"

for name in child-1 child-2 worker-1 worker-2; do
  container stop "${name}" >/dev/null 2>&1 || true
  container rm "${name}" >/dev/null 2>&1 || true
done
rm -f "${DOCKER_ROOT}/.generated/env.sh"
echo "Removed child-1 and child-2 (and leftover worker-1 / worker-2, if they existed)"
echo "Remove SSH E2E artifacts: rm -rf test/artifacts/ssh-e2e"
