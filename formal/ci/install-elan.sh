#!/usr/bin/env bash
# Install a pinned elan release (see elan-pin.env). Idempotent when ~/.elan/bin/elan exists.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=elan-pin.env
source "$ROOT/elan-pin.env"

if [[ -x "${HOME}/.elan/bin/elan" ]]; then
  echo "elan already installed (cache hit); skipping bootstrap"
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -sSfL "$ELAN_BINARY_URL" -o "$tmp/elan-installer.tar.gz"
  echo "${ELAN_BINARY_SHA256}  $tmp/elan-installer.tar.gz" | sha256sum -c -
  tar -xf "$tmp/elan-installer.tar.gz" -C "$tmp"
  chmod +x "$tmp/elan-init"
  "$tmp/elan-init" -y --default-toolchain none --no-modify-path
fi

"${HOME}/.elan/bin/elan" --version