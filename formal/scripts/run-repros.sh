#!/usr/bin/env bash
# Run reproducers for every refuted registry entry (julia-in-lean convention).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
JULIA=${JULIA:-julia}

AUDIT_OUT=.lake/audit.out
test -s "$AUDIT_OUT" || { echo "FAIL missing $AUDIT_OUT; run scripts/audit.sh first"; exit 1; }

REPO_ROOT="$(cd .. && pwd)"

run_repro_script () {
  local id="$1"
  local script="$2"
  local out rc
  set +e
  out="$("$JULIA" --project="$REPO_ROOT/lib/DistSSHBase" "$script" </dev/null 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "FAIL $id: reproducer exited $rc"
    sed 's/^/    /' <<<"$out" | tail -20
    return 1
  fi
  if grep -qx "REPRODUCED $id" <<<"$out"; then
    echo "OK $id"
    return 0
  fi
  echo "FAIL $id: reproducer did not print 'REPRODUCED $id'"
  sed 's/^/    /' <<<"$out" | tail -20
  return 1
}

self_test_repros () {
  local tmpdir failures=0
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  cat >"$tmpdir/marker-then-throw.jl" <<'EOF'
println("REPRODUCED selftest-marker-then-throw")
error("after marker")
EOF
  if run_repro_script "selftest-marker-then-throw" "$tmpdir/marker-then-throw.jl"; then
    echo "FAIL selftest: expected non-zero exit after REPRODUCED marker"
    failures=$((failures + 1))
  else
    echo "OK selftest-marker-then-throw"
  fi

  cat >"$tmpdir/clean.jl" <<'EOF'
println("REPRODUCED selftest-clean")
EOF
  if ! run_repro_script "selftest-clean" "$tmpdir/clean.jl"; then
    echo "FAIL selftest: clean reproducer should pass"
    failures=$((failures + 1))
  fi

  [[ $failures -eq 0 ]]
}

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
  if run_repro_script "$id" "$script"; then
    :
  else
    failures=$((failures + 1))
  fi
done < <(sed -n 's/^REFUTED //p' "$AUDIT_OUT")

self_failures=0
if ! self_test_repros; then
  self_failures=1
fi
failures=$((failures + self_failures))

echo "REPROS $count FAILURES $failures"
[[ $failures -eq 0 ]]