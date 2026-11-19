#!/usr/bin/env bash
# Local push gate. Same pins as CI. Does not install tools.
#
#   ./scripts/check.sh
#
# On success prints `HEAD <sha>: passed`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

RUNIC_COMPAT="${ROOT}/.github/runic/Project.toml"
JETLS_ACTION="${ROOT}/.github/actions/jetls-check/action.yml"
INSTALL="${ROOT}/.github/install-agent-tools.sh"

die() {
  echo "check: $*" >&2
  exit 1
}

pin_help() {
  echo "check: pin: $1" >&2
  echo "check: install with ${INSTALL#"${ROOT}/"}" >&2
  exit 1
}

if [[ -n "$(git status --porcelain)" ]]; then
  die "git status is not empty. Commit first, then rerun ./scripts/check.sh on that commit."
fi

# macOS and Linux, including WSL2, use this same gate.
# Native Windows is not a supported environment.
case "$(uname -s)" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "native Windows is not supported. Use WSL2 Ubuntu. This gate then uses the Linux conditions."
    ;;
  *)
    die "unsupported OS $(uname -s). Supported environments are macOS and Linux, including WSL2 Ubuntu."
    ;;
esac

# Julia 1.13 from PATH. juliaup's `julia +1.13` is accepted. No fixed install path.
JULIA=()
if command -v julia >/dev/null 2>&1 && julia +1.13 --startup-file=no -e 'exit(0)' >/dev/null 2>&1; then
  JULIA=(julia +1.13)
elif command -v julia >/dev/null 2>&1 && julia --startup-file=no -e 'exit(VERSION>=v"1.13" && VERSION<v"1.14" ? 0 : 1)' >/dev/null 2>&1; then
  JULIA=(julia)
else
  pin_help "Julia 1.13 is not on PATH"
fi
JULIA_BIN="$("${JULIA[@]}" --startup-file=no -e 'print(joinpath(Sys.BINDIR, "julia"))')"
if [[ ! -x "${JULIA_BIN}" ]]; then
  pin_help "Julia 1.13 binary is missing"
fi
depot="$("${JULIA[@]}" --startup-file=no -e 'print(DEPOT_PATH[1])')"

runic_pin="$(sed -n -E 's/^Runic = "=([^"]+)".*/\1/p' "${RUNIC_COMPAT}" | head -1)"
if [[ ! "${runic_pin}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pin_help "Runic compat pin missing in .github/runic/Project.toml"
fi

jetls_pin="$(grep -E -m 1 -o 'rev="[0-9]{4}-[0-9]{2}-[0-9]{2}"' "${JETLS_ACTION}" || true)"
jetls_pin="${jetls_pin#rev=\"}"
jetls_pin="${jetls_pin%\"}"
if [[ ! "${jetls_pin}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  pin_help "JETLS date pin missing in .github/actions/jetls-check/action.yml"
fi

runic_bin="${depot}/bin/runic"
jetls_bin="${depot}/bin/jetls"
jetls_manifest="${depot}/environments/apps/JETLS/Manifest.toml"

if [[ ! -x "${runic_bin}" ]]; then
  pin_help "Runic ${runic_pin} app is missing (${runic_bin})"
fi
runic_ver="$("${runic_bin}" --version 2>/dev/null | sed -n 's/^runic version \([^,]*\).*/\1/p' || true)"
if [[ "${runic_ver}" != "${runic_pin}" ]]; then
  pin_help "Runic app is ${runic_ver:-unknown}, pin is ${runic_pin}"
fi
same_file() {
  if ! command -v realpath >/dev/null 2>&1; then
    pin_help "realpath is missing, so the pin cannot be compared"
  fi
  [[ "$(realpath "$1")" == "$(realpath "$2")" ]]
}

if command -v runic >/dev/null 2>&1; then
  path_runic="$(command -v runic)"
  if ! same_file "${path_runic}" "${runic_bin}"; then
    pin_help "PATH runic is ${path_runic}, not the pin ${runic_pin}"
  fi
fi

if [[ ! -x "${jetls_bin}" ]]; then
  pin_help "JETLS ${jetls_pin} app is missing (${jetls_bin})"
fi
jetls_got=""
if [[ -f "${jetls_manifest}" ]]; then
  jetls_got="$(awk '
    /^\[\[deps\.JETLS\]\]/ { in_jetls = 1; next }
    /^\[\[deps\./ { if (in_jetls) exit }
    in_jetls && /^repo-rev = / {
      line = $0
      sub(/^repo-rev = /, "", line)
      gsub(/"/, "", line)
      print line
      exit
    }
  ' "${jetls_manifest}")"
fi
if [[ "${jetls_got}" != "${jetls_pin}" ]]; then
  pin_help "JETLS app rev is ${jetls_got:-missing}, pin is ${jetls_pin}"
fi
if command -v jetls >/dev/null 2>&1; then
  path_jetls="$(command -v jetls)"
  if ! same_file "${path_jetls}" "${jetls_bin}"; then
    pin_help "PATH jetls is ${path_jetls}, not the pin ${jetls_pin}"
  fi
fi

JULIA_APPS_JULIA_CMD="${JULIA_BIN}" "${runic_bin}" --check --diff .

# Exactly one final newline on text files changed vs origin/main.
while IFS= read -r -d '' f; do
  [[ -f "${f}" ]] || continue
  numstat="$(git diff --numstat origin/main...HEAD -- "${f}")"
  if [[ "${numstat}" == -* ]]; then
    continue
  fi
  if [[ ! -s "${f}" ]]; then
    continue
  fi
  last="$(tail -c 1 "${f}" || true)"
  if [[ "${last}" != $'\n' ]]; then
    die "${f} does not end with exactly one newline"
  fi
  if [[ "$(tail -c 2 "${f}" | wc -c | tr -d ' ')" -eq 2 ]]; then
    prev="$(tail -c 2 "${f}" | head -c 1 || true)"
    if [[ "${prev}" == $'\n' ]]; then
      die "${f} ends with more than one newline"
    fi
  fi
done < <(git diff --name-only -z origin/main...HEAD)

git diff --check origin/main...HEAD

JULIA_APPS_JULIA_CMD="${JULIA_BIN}" "${ROOT}/.github/jetls-check.sh" --progress=none

for lint in banned-words.sh agents-md.sh skip-reasons.sh new-comments.sh; do
  script="${ROOT}/scripts/lint/${lint}"
  if [[ ! -x "${script}" ]]; then
    die "missing ${script#"${ROOT}/"}"
  fi
  "${script}"
done

"${ROOT}/scripts/docs.sh" static
"${ROOT}/scripts/docs.sh" maybe

sha="$(git rev-parse HEAD)"
echo "HEAD ${sha}: passed"
