#!/usr/bin/env bash
# Install pinned elan from formal/ci/elan-pin.env (every CI run; no Actions cache).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=elan-pin.env
source "$ROOT/elan-pin.env"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -sSfL "$ELAN_BINARY_URL" -o "$tmp/elan-installer.tar.gz"
echo "${ELAN_BINARY_SHA256}  $tmp/elan-installer.tar.gz" | sha256sum -c -
tar -xf "$tmp/elan-installer.tar.gz" -C "$tmp"
chmod +x "$tmp/elan-init"
"$tmp/elan-init" -y --default-toolchain none --no-modify-path

"${HOME}/.elan/bin/elan" --version