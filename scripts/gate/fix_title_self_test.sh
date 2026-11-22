#!/usr/bin/env bash
# Self-test Conventional Commit fix-title trigger used in CI.yml and judge.sh.
set -euo pipefail

fail() {
  echo "fix_title_self_test: $*" >&2
  exit 1
}

fix_title_triggers() {
  local title="$1"
  local lower="${title,,}"
  [[ "${lower}" == fix:* || "${lower}" == fix\(* ]]
}

for t in "Fix typo" "fixture cleanup" "Fixing typo"; do
  if fix_title_triggers "${t}"; then
    fail "must not trigger: ${t}"
  fi
done

for t in "fix: typo" "fix(scope): typo" "FIX(x): typo"; do
  fix_title_triggers "${t}" || fail "must trigger: ${t}"
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=judge_self_test.sh
# Reuse judge_self_test skip list via a minimal sourced fragment is overkill; call verify only.
"${ROOT}/scripts/gate/judge_matrix_verify.sh" >/dev/null || fail "judge_matrix_verify"

echo "ok"