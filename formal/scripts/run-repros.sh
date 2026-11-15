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

# Like run_repro_script but captures output without printing (for self-tests).
run_repro_script_silent () {
  local id="$1"
  local script="$2"
  local _out_file="${3:-}"
  local out rc
  set +e
  out="$("$JULIA" --project="$REPO_ROOT/lib/DistSSHBase" "$script" </dev/null 2>&1)"
  rc=$?
  set -e
  [[ -n "$_out_file" ]] && printf '%s' "$out" >"$_out_file"
  if [[ $rc -ne 0 ]]; then
    return 1
  fi
  if grep -qx "REPRODUCED $id" <<<"$out"; then
    return 0
  fi
  return 2
}

self_test_repros () {
  local tmpdir expected=2 passed=0 failures=0 captured
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  cat >"$tmpdir/marker-then-throw.jl" <<'EOF'
println("REPRODUCED selftest-marker-then-throw")
error("after marker")
EOF
  if run_repro_script_silent "selftest-marker-then-throw" "$tmpdir/marker-then-throw.jl" "$tmpdir/marker.out"; then
    echo "SELFTEST marker-then-throw: FAIL (expected non-zero exit after marker)"
    captured="$(cat "$tmpdir/marker.out")"
    sed 's/^/    /' <<<"$captured" | tail -20
    failures=$((failures + 1))
  else
    echo "SELFTEST marker-then-throw: rejected as expected"
    passed=$((passed + 1))
  fi

  cat >"$tmpdir/clean.jl" <<'EOF'
println("REPRODUCED selftest-clean")
EOF
  if run_repro_script_silent "selftest-clean" "$tmpdir/clean.jl" "$tmpdir/clean.out"; then
    echo "SELFTEST clean: accepted as expected"
    passed=$((passed + 1))
  else
    echo "SELFTEST clean: FAIL (expected exit 0 with marker)"
    captured="$(cat "$tmpdir/clean.out")"
    sed 's/^/    /' <<<"$captured" | tail -20
    failures=$((failures + 1))
  fi

  if [[ $failures -eq 0 ]]; then
    echo "SELFTESTS $passed/$expected OK"
    return 0
  fi
  echo "SELFTESTS $passed/$expected FAIL ($failures unexpected)"
  return 1
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

self_rc=0
self_test_repros || self_rc=$?

echo "REPROS $count FAILURES $failures"
if [[ $failures -ne 0 ]] || [[ $self_rc -ne 0 ]]; then
  exit 1
fi