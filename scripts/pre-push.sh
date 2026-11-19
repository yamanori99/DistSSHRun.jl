#!/usr/bin/env bash
# distsshrun-check-gate
# Installed into .git/hooks/pre-push by scripts/check.sh.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "${root}"
# shellcheck source=section.sh
source "${root}/scripts/section.sh"
sha="$(git rev-parse HEAD)"
stamp="${root}/.git/check-gate-ok"
if [[ -f "${stamp}" ]] && [[ "$(cat "${stamp}")" == "${sha}" ]]; then
  section "check: already passed ${sha}"
  exit 0
fi
exec ./scripts/check.sh
