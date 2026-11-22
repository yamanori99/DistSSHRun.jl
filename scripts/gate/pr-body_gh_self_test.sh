#!/usr/bin/env bash
# Self-test gh optional paths for pr-body.sh and check.sh branches.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

fail() {
  echo "pr-body_gh_self_test: $*" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "${tmpdir}"; }
trap cleanup EXIT

# shellcheck source=gh-pr-note.sh
source "${ROOT}/scripts/gate/gh-pr-note.sh"

printf 'no pull requests found for branch\n' >"${tmpdir}/nopr.txt"
set +e
gh_pr_note_or_continue "${tmpdir}/nopr.txt"
rc=$?
set -e
[[ "${rc}" -eq 2 ]] || fail "no PR rc=${rc}"

printf 'HTTP 401: Bad credentials\n' >"${tmpdir}/auth.txt"
gh_pr_note_or_continue "${tmpdir}/auth.txt" || fail "auth"
[[ "${gh_pr_note_reason}" == gh\ not\ authenticated ]] || fail "auth reason"

_no_gh_path() {
  local p dir
  p="${PATH}"
  if command -v gh >/dev/null 2>&1; then
    dir="$(dirname "$(command -v gh)")"
    p="$(tr ':' '\n' <<<"${p}" | grep -Fxv "${dir}" | paste -sd: -)"
  fi
  printf '%s\n' "${p}"
}

mkdir -p "${tmpdir}/bin"
cat >"${tmpdir}/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo 'not logged into any GitHub hosts' >&2
exit 1
EOF
chmod +x "${tmpdir}/bin/gh"

export GATE_DIFF_BASE=origin/main GATE_DIFF_HEAD=HEAD
out="$(env PATH="${tmpdir}/bin:$(_no_gh_path)" "${ROOT}/scripts/gate/pr-body.sh" 2>&1)" || fail "pr-body unauthenticated gh exit"
grep -Fq 'note:' <<<"${out}" || fail "pr-body missing note"
grep -Fq 'pr body lint skipped' <<<"${out}" || fail "pr-body skip text"

out="$(env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "${ROOT}/scripts/gate/pr-body.sh" 2>&1)"
grep -Fq 'note: gh not on PATH' <<<"${out}" || grep -Fq 'pr body: no pull request' <<<"${out}" || fail "pr-body without gh"

if command -v gh >/dev/null 2>&1; then
  out="$(env PATH="$(_no_gh_path)" "${ROOT}/scripts/gate/pr-body.sh" 2>&1)"
  grep -Fq 'pr body: no pull request' <<<"${out}" || grep -Fq 'note:' <<<"${out}" || fail "pr-body open branch"
fi

body="$(mktemp)"
paths="$(mktemp)"
cat >"${body}" <<'EOF'
## Summary

Bad.

## Testing

prose only

## Risk

## Revert
EOF
echo "README.md" >"${paths}"
export GATE_PR_BODY_FILE="${body}" GATE_PR_PATHS_FILE="${paths}"
if bash "${ROOT}/scripts/gate/pr-body.sh" >/dev/null 2>&1; then
  fail "lintable body must still fail"
fi

echo "ok"
