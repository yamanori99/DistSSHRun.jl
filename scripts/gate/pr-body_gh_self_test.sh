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

mkdir -p "${tmpdir}/tools" "${tmpdir}/bin"
for tool in bash git grep sed awk tr mktemp rm cat printf dirname readlink env; do
  if command -v "${tool}" >/dev/null 2>&1; then
    ln -sf "$(command -v "${tool}")" "${tmpdir}/tools/${tool}"
  fi
done
# Do not put /bin or /usr/bin on PATH: ubuntu images ship gh in both.
TOOLS_PATH="${tmpdir}/tools"

cat >"${tmpdir}/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo 'not logged into any GitHub hosts' >&2
exit 1
EOF
chmod +x "${tmpdir}/bin/gh"
STUB_PATH="${tmpdir}/bin:${TOOLS_PATH}"

printf 'no pull requests found for branch\n' >"${tmpdir}/nopr.txt"
set +e
PATH="${STUB_PATH}" gh_pr_note_or_continue "${tmpdir}/nopr.txt"
rc=$?
set -e
[[ "${rc}" -eq 2 ]] || fail "no PR rc=${rc}"

printf 'HTTP 401: Bad credentials\n' >"${tmpdir}/auth.txt"
PATH="${STUB_PATH}" gh_pr_note_or_continue "${tmpdir}/auth.txt" || fail "auth"
[[ "${gh_pr_note_reason}" == gh\ not\ authenticated ]] || fail "auth reason"

export GATE_DIFF_BASE=origin/main GATE_DIFF_HEAD=HEAD
out="$(env PATH="${STUB_PATH}" "${ROOT}/scripts/gate/pr-body.sh" 2>&1)" || fail "pr-body unauthenticated gh exit"
grep -Fq 'note:' <<<"${out}" || fail "pr-body missing note"
grep -Fq 'pr body lint skipped' <<<"${out}" || fail "pr-body skip text"

out="$(env PATH="${TOOLS_PATH}" "${ROOT}/scripts/gate/pr-body.sh" 2>&1)" || fail "pr-body missing gh exit"
grep -Fq 'note: gh not on PATH' <<<"${out}" || fail "pr-body missing gh note: ${out}"

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
if env PATH="${TOOLS_PATH}" bash "${ROOT}/scripts/gate/pr-body.sh" >/dev/null 2>&1; then
  fail "lintable body must still fail"
fi

echo "ok"
