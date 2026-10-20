#!/usr/bin/env bash
# Install apt packages inside WSL while the caller is still root.
# Vampire/setup-wsl must not apt-get. A stuck wsl.exe keeps stdio open,
# so that step's timeout-minutes does not reap it. timeout here does.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "wsl-apt.sh needs root" >&2
  exit 1
fi
if [[ "$#" -eq 0 ]]; then
  echo "wsl-apt.sh needs package names" >&2
  exit 1
fi

missing=()
for pkg in "$@"; do
  status="$(dpkg-query -W -f '${Status}' "$pkg" 2>/dev/null || true)"
  if [[ "$status" != "install ok installed" ]]; then
    missing+=("$pkg")
  fi
done
[[ ${#missing[@]} -eq 0 ]] && exit 0

export DEBIAN_FRONTEND=noninteractive
timeout 180 apt-get update -qq
timeout 180 apt-get install -y --no-install-recommends "${missing[@]}"
