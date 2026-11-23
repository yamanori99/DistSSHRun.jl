#!/usr/bin/env bash
# Scan commits on HEAD that are not on origin/main. Full history stays on the Scan workflow.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "note: gitleaks not found; commit range unchecked locally, CI will check"
  exit 0
fi

if ! git rev-parse --verify --quiet origin/main >/dev/null; then
  echo "gitleaks: origin/main is missing" >&2
  exit 1
fi

range="origin/main...HEAD"
count="$(git rev-list --count "${range}")"
if [[ "${count}" == "0" ]]; then
  echo "note: gitleaks: no commits versus origin/main"
  exit 0
fi

exec gitleaks detect --source . --redact=100 --log-opts="${range}"
