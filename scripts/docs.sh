#!/usr/bin/env bash
# Docs gate.
#
#   ./scripts/docs.sh static
#   ./scripts/docs.sh maybe
#   ./scripts/docs.sh build [--linkcheck]
#
# static checks the tree. maybe runs make.jl only when origin/main...HEAD
# touches docs/ or a docstring line. build instantiates and runs make.jl.
# linkcheck is off unless --linkcheck is passed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
# shellcheck source=section.sh
source "${ROOT}/scripts/section.sh"
# shellcheck source=julia.sh
source "${ROOT}/scripts/julia.sh"

die() {
  echo "docs: $*" >&2
  exit 1
}

usage() {
  echo "usage: docs.sh static|maybe|build [--linkcheck]" >&2
  exit 2
}

# Same environments as scripts/check.sh. Native Windows stops here.
case "$(uname -s)" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "native Windows is not supported. Use WSL2 Ubuntu. This script then uses the Linux conditions."
    ;;
  *)
    die "unsupported OS $(uname -s). Supported environments are macOS and Linux, including WSL2 Ubuntu."
    ;;
esac

use_julia_1_13 || die "Julia 1.13 is not on PATH"

static() {
  section "docs: static"
  files="$(git diff --name-only origin/main...HEAD)"
  if printf '%s\n' "${files}" | grep -q 'social-preview-static\.svg$'; then
    if ! printf '%s\n' "${files}" | grep -q 'social-preview-static\.png$'; then
      die "social-preview-static.svg changed without social-preview-static.png"
    fi
  fi
  "${ROOT}/scripts/lint/run.sh" docs-static
  section "docs: static ok"
}

build() {
  section "docs: build"
  local linkcheck=0
  if [[ "${1:-}" == "--linkcheck" ]]; then
    linkcheck=1
  elif [[ -n "${1:-}" ]]; then
    echo "usage: docs.sh build [--linkcheck]" >&2
    exit 2
  fi
  "${JULIA[@]}" --project=docs --startup-file=no -e 'using Pkg; Pkg.Registry.add("General"); Pkg.instantiate()'
  if [[ "${linkcheck}" == 1 ]]; then
    DOCUMENTER_LINKCHECK=1 "${JULIA[@]}" --project=docs --startup-file=no docs/make.jl
  else
    "${JULIA[@]}" --project=docs --startup-file=no docs/make.jl
  fi
  section "docs: build ok"
}

maybe() {
  section "docs: maybe"
  local answer
  answer="$("${ROOT}/scripts/lint/run.sh" doc-touch)"
  if [[ "${answer}" == "yes" ]]; then
    build
  else
    echo "docs: make.jl skipped"
  fi
  section "docs: maybe ok"
}

case "${1:-}" in
  static) static ;;
  maybe) maybe ;;
  build) build "${2:-}" ;;
  *) usage ;;
esac
