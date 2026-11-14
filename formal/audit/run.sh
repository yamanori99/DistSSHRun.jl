#!/usr/bin/env bash
# Build audit for the Lean formal model: no sorry/native_decide and no sorry axioms.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FORMAL="$ROOT/formal"
LAKE_DIR="$FORMAL/DistSSHBase"

if rg -n --glob '*.lean' -e '\bsorry\b' -e '\bnative_decide\b' "$FORMAL"; then
  echo "audit failed: sorry or native_decide found under formal/" >&2
  exit 1
fi

cd "$LAKE_DIR"
lake build

AXIOM_LOG="$(mktemp)"
trap 'rm -f "$AXIOM_LOG"' EXIT

lake env lean "$FORMAL/audit/axioms.lean" &> "$AXIOM_LOG"

if rg -q 'sorryAxiom|native_decide' "$AXIOM_LOG"; then
  echo "audit failed: forbidden axioms in theorem dependencies" >&2
  cat "$AXIOM_LOG"
  exit 1
fi

# Each `#print axioms` block should list only standard Lean axioms.
if ! rg -q 'signaled_branch.*depends on axioms:' "$AXIOM_LOG"; then
  echo "audit failed: missing axioms report for signaled_branch" >&2
  cat "$AXIOM_LOG"
  exit 1
fi

echo "axiom audit ok"
cat "$AXIOM_LOG"