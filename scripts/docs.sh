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

die() {
  echo "docs: $*" >&2
  exit 1
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

if command -v julia >/dev/null 2>&1 && julia +1.13 --startup-file=no -e 'exit(0)' >/dev/null 2>&1; then
  JULIA=(julia +1.13)
elif command -v julia >/dev/null 2>&1; then
  JULIA=(julia)
else
  die "Julia is not on PATH"
fi

static() {
  files="$(git diff --name-only origin/main...HEAD)"
  if printf '%s\n' "${files}" | grep -q 'social-preview-static\.svg$'; then
    if ! printf '%s\n' "${files}" | grep -q 'social-preview-static\.png$'; then
      die "social-preview-static.svg changed without social-preview-static.png"
    fi
  fi
  "${ROOT}/scripts/lint/run.sh" docs-static
}

build() {
  local linkcheck=0
  if [[ "${1:-}" == "--linkcheck" ]]; then
    linkcheck=1
  elif [[ -n "${1:-}" ]]; then
    die "unknown build argument ${1}"
  fi
  "${JULIA[@]}" --project=docs --startup-file=no -e 'using Pkg; Pkg.Registry.add("General"); Pkg.instantiate()'
  if [[ "${linkcheck}" == 1 ]]; then
    DOCUMENTER_LINKCHECK=1 "${JULIA[@]}" --project=docs --startup-file=no docs/make.jl
  else
    "${JULIA[@]}" --project=docs --startup-file=no docs/make.jl
  fi
}

maybe() {
  local answer
  answer="$("${ROOT}/scripts/lint/run.sh" doc-touch)"
  if [[ "${answer}" == "yes" ]]; then
    build
  else
    echo "docs: make.jl skipped"
  fi
}

case "${1:-}" in
  static) static ;;
  maybe) maybe ;;
  build) build "${2:-}" ;;
  *) die "usage: docs.sh static|maybe|build [--linkcheck]" ;;
esac
