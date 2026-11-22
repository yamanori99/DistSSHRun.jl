#!/usr/bin/env bash
# When gh is missing or cannot authenticate, print a non-failing note and exit 0.
# Source after writing tool errors to a file. Sets gh_pr_note_reason on success.
gh_pr_note_or_continue() {
  local err_file="$1"
  if ! command -v gh >/dev/null 2>&1; then
    gh_pr_note_reason="gh not on PATH"
    return 0
  fi
  if grep -q 'no pull requests found' "${err_file}"; then
    gh_pr_note_reason=""
    return 2
  fi
  if grep -qiE '(not logged into|not authenticated|authentication failed|HTTP 401|gh auth login)' "${err_file}"; then
    gh_pr_note_reason="gh not authenticated"
    return 0
  fi
  gh_pr_note_reason=""
  return 1
}
