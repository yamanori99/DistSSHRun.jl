#!/usr/bin/env bash
# Flag workflow jobs that touch repo files before actions/checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOWS="${ROOT}/.github/workflows"

die() {
  echo "workflow_checkout_verify: $*" >&2
  exit 1
}

verify_file() {
  local file="$1"
  local relpath="${file#"${ROOT}/"}"
  [[ "${relpath}" == "${file}" ]] && relpath="${file}"
  awk -v relpath="${relpath}" '
    function flush_job(    ) {
      job = ""
      checkout = 0
      in_run = 0
    }
    function report(line, text) {
      printf "workflow_checkout_verify: %s job %s:%d: step uses repo without checkout: %s\n", relpath, job, line, text > "/dev/stderr"
      fail = 1
    }
    /^jobs:/ { in_jobs = 1; next }
    in_jobs && /^[^ #]/ && $0 !~ /^  / { in_jobs = 0; flush_job(); next }
    !in_jobs { next }
    /^  [a-zA-Z0-9_.-]+:/ {
      sub(/^  /, "")
      sub(/:.*/, "")
      job = $0
      checkout = 0
      in_run = 0
      next
    }
    job == "" { next }
    /uses:[[:space:]]*actions\/checkout@/ { checkout = 1 }
    in_run {
      if ($0 ~ /^      /) {
        if (index($0, "./.github") || index($0, "scripts/") || index($0, "julia --project") ||
            index($0, "bash .github") || index($0, "bash ./")) {
          if (!checkout) report(NR, $0)
        }
      } else if ($0 ~ /^    [a-zA-Z]/) {
        in_run = 0
      }
      next
    }
    /^[[:space:]]+run:[[:space:]]*\|[[:space:]]*$/ { in_run = 1; next }
    {
      line = $0
      needs = (index(line, "uses: ./.github/") > 0 || index(line, "hashFiles(") > 0)
      if (!needs && index(line, "run:") > 0) {
        body = line
        sub(/^.*run:/, "", body)
        needs = (index(body, "./.github") || index(body, ".github/") || index(body, "./scripts") ||
                 index(body, "scripts/") || index(body, "julia --project") || index(body, "bash .github") ||
                 index(body, "bash ./"))
      }
      if (needs && !checkout) report(NR, line)
    }
    END { exit fail }
  ' "${file}"
}

verify_all() {
  local fail=0 f
  if (($# > 0)); then
    for f in "$@"; do
      verify_file "${f}" || fail=1
    done
  else
    for f in "${WORKFLOWS}"/*.yml; do
      [[ -f "${f}" ]] || continue
      verify_file "${f}" || fail=1
    done
  fi
  return "${fail}"
}

self_test() {
  local tmp good bad
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  good="${tmp}/good.yml"
  bad="${tmp}/bad.yml"
  cat >"${good}" <<'EOF'
name: x
on: workflow_dispatch
jobs:
  ok:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
      - run: bash .github/ci-alert-notify.sh
EOF
  cat >"${bad}" <<'EOF'
name: x
on: workflow_dispatch
jobs:
  notify:
    runs-on: ubuntu-latest
    steps:
      - run: bash .github/ci-alert-notify.sh
EOF
  verify_all "${good}" || die "self-test: good fixture failed"
  if verify_all "${bad}" 2>/dev/null; then
    die "self-test: bad fixture should fail"
  fi
  echo "ok  workflow_checkout_verify self-test"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

if ! verify_all; then
  exit 1
fi
