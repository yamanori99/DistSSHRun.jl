#!/usr/bin/env bash
# All diff lint modes (+ self-test when scripts/lint/ changed, + runtests inventory).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

GATE_DIFF_BASE="${GATE_DIFF_BASE:-origin/main}"
GATE_DIFF_HEAD="${GATE_DIFF_HEAD:-HEAD}"
export GATE_DIFF_RANGE="${GATE_DIFF_BASE}...${GATE_DIFF_HEAD}"

lint_names=(banned-words agents-md skip-reasons new-comments stdlib-compat ssh-argv drive-hooks aqua-run runtests)
for lint in "${lint_names[@]}"; do
  script="${ROOT}/scripts/lint/${lint}.sh"
  if [[ ! -x "${script}" ]]; then
    echo "lint: missing ${script#"${ROOT}/"}" >&2
    exit 1
  fi
  "${script}"
done

if git diff --name-only "${GATE_DIFF_RANGE}" | grep -q '^scripts/lint/'; then
  "${ROOT}/scripts/lint/run.sh" self-test
fi