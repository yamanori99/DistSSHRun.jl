#!/usr/bin/env bash
# Emit Julia --code-coverage=@… flags for E2E (stdout). Kit sources only; not --code-coverage=user.
# Child CLIs inherit scoped flags via Base.julia_cmd() without writing .cov into shipped suite trees.
set -euo pipefail

kit_root="${1:?kit root}"
dirs=(
  "${kit_root}/src"
  "${kit_root}/lib/DistSSHBase/src"
  "${kit_root}/lib/DistSSHUp/src"
  "${kit_root}/lib/DistSSHShip/src"
  "${kit_root}/lib/DistSSHHeartbeat/src"
)
for d in "${dirs[@]}"; do
  printf '%s\0' --code-coverage=@"${d}"
done
