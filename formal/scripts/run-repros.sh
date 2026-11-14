#!/usr/bin/env bash
# Run reproducers for every refuted registry entry (julia-in-lean convention).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
JULIA=${JULIA:-julia}

AUDIT_OUT=.lake/audit.out
test -s "$AUDIT_OUT" || { echo "FAIL missing $AUDIT_OUT; run scripts/audit.sh first"; exit 1; }

failures=0
count=0
while read -r id; do
  count=$((count + 1))
  script="repro/$id.jl"
  if [[ ! -f "$script" ]]; then
    echo "FAIL $id: missing $script"
    failures=$((failures + 1))
    continue
  fi
  REPO_ROOT="$(cd .. && pwd)"
  out="$("$JULIA" --project="$REPO_ROOT/lib/DistSSHBase" "$script" </dev/null 2>&1 || true)"
  if grep -qx "REPRODUCED $id" <<<"$out"; then
    echo "OK $id"
  else
    echo "FAIL $id: reproducer did not print 'REPRODUCED $id'"
    sed 's/^/    /' <<<"$out" | tail -20
    failures=$((failures + 1))
  fi
done < <(sed -n 's/^REFUTED //p' "$AUDIT_OUT")

echo "REPROS $count FAILURES $failures"
[[ $failures -eq 0 ]]