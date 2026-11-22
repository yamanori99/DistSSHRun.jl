#!/usr/bin/env bash
# Open or close one alert issue from monitored job results.
# Env: GH_TOKEN, TITLE, RUN_URL, BODY_PREFIX (short workflow hint)
# Env: MONITOR_RESULTS — newline-separated "name:result" (failure and cancelled count as failed).
set -euo pipefail

title="${TITLE:?}"
run_url="${RUN_URL:?}"
prefix="${BODY_PREFIX:-}"

failed=false
all_ok=true
saw_success=false
while IFS= read -r line || [[ -n "${line:-}" ]]; do
  [[ -z "${line:-}" ]] && continue
  result="${line#*:}"
  case "${result}" in
    success) saw_success=true ;;
    skipped) ;;
    failure | cancelled) failed=true; all_ok=false ;;
    *) all_ok=false ;;
  esac
done <<< "${MONITOR_RESULTS:-}"

body="${prefix}Latest run: ${run_url}

Failed or cancelled jobs:
$(grep -E ':(failure|cancelled)$' <<< "${MONITOR_RESULTS:-}" | sed 's/^/  - /' || true)"

gh label create alert --force --description "Auto: scheduled check failed (E2E weekly, CI weekly, Runic)" --color "ff4d00" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1 || true
existing="$(gh issue list --repo "$GITHUB_REPOSITORY" --state open --label alert --search "in:title ${title}" --json number --jq '.[0].number // empty')"

if [[ "${failed}" == "true" ]]; then
  if [[ -n "${existing}" ]]; then
    gh issue comment "${existing}" --repo "$GITHUB_REPOSITORY" --body "${body}"
  else
    gh issue create --repo "$GITHUB_REPOSITORY" --title "${title}" --label alert --body "${body}"
  fi
elif [[ "${all_ok}" == "true" && "${saw_success}" == "true" && -n "${existing}" ]]; then
  gh issue close "${existing}" --repo "$GITHUB_REPOSITORY" --reason completed --comment "Latest run succeeded: ${run_url}"
fi
