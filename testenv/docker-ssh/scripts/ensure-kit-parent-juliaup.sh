#!/usr/bin/env bash
# Ensure the kit parent has juliaup + default/alt channels for
# `setup --juliaup parent` SSH E2E. CI uses julia-actions/setup-julia
# (no juliaup); remotes already bake both channels in the worker image.
#
# Expects JULIA_DEFAULT_CHANNEL / JULIA_ALT_CHANNEL (from julia-channels.sh).
# Updates both channels, then sets juliaup default back to the default channel
# before up.sh launches the suite. The suite pins that julia's Sys.BINDIR.
#
# Juliaup resolution matches DistSSHKit.local_juliaup_candidates (home install,
# then macOS Homebrew). Official install.julialang.org refuses when Homebrew
# juliaup is already present, so Homebrew alone must count as "installed".
set -euo pipefail

# shellcheck source=retry.sh
source "$(dirname "$0")/retry.sh"

: "${JULIA_DEFAULT_CHANNEL:?JULIA_DEFAULT_CHANNEL unset (source julia-channels.sh first)}"
: "${JULIA_ALT_CHANNEL:?JULIA_ALT_CHANNEL unset (source julia-channels.sh first)}"

find_juliaup() {
  local c
  for c in \
    "${HOME}/.juliaup/bin/juliaup" \
    /opt/homebrew/bin/juliaup \
    /usr/local/bin/juliaup
  do
    if [[ -x "${c}" ]]; then
      printf '%s\n' "${c}"
      return 0
    fi
  done
  return 1
}

JU="$(find_juliaup || true)"

if [[ -z "${JU}" ]]; then
  echo "kit parent: installing juliaup (default channel ${JULIA_DEFAULT_CHANNEL})..."
  _distsshkit_retry "kit parent juliaup install" \
    _distsshkit_install_juliaup "${JULIA_DEFAULT_CHANNEL}"
  JU="$(find_juliaup || true)"
fi

if [[ -z "${JU}" ]]; then
  echo "juliaup missing after install (tried: \$HOME/.juliaup/bin/juliaup, /opt/homebrew/bin/juliaup, /usr/local/bin/juliaup)" >&2
  exit 1
fi

# Both channels must exist so E2E can mismatch then realign.
# `add` / `update` download the version db from julialang-s3. That request
# is outside the installer curl retry, and a timeout used to fail the job.
_distsshkit_ensure_kit_channels() {
  local ju="$1"
  "${ju}" add "${JULIA_DEFAULT_CHANNEL}"
  "${ju}" add "${JULIA_ALT_CHANNEL}"
  # Current patch before the suite starts. A later juliaup version-db check
  # (setup --juliaup parent) must not delete the install the suite is running.
  "${ju}" update "${JULIA_DEFAULT_CHANNEL}"
  "${ju}" update "${JULIA_ALT_CHANNEL}"
  "${ju}" default "${JULIA_DEFAULT_CHANNEL}"
}
_distsshkit_retry "kit parent juliaup channels" \
  _distsshkit_ensure_kit_channels "${JU}"

echo "kit parent juliaup: ${JU} ($("${JU}" --version 2>/dev/null || echo ok); channels ${JULIA_DEFAULT_CHANNEL} / ${JULIA_ALT_CHANNEL})"
