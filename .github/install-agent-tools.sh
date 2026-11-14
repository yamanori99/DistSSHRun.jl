#!/usr/bin/env bash
# Idempotent Runic + JETLS install for Cursor Cloud Agent Builds and local use.
# JETLS rev is read from .github/actions/jetls-check/action.yml (same pin as CI).
#
# Optional INSTALL_AGENT_TOOLS_DEPOT: depot root for this script only (testing).
# Do not export HOME or JULIA_DEPOT_PATH; prefix Julia/Pkg calls when needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${ROOT}/.github/actions/jetls-check/action.yml"
JULIAUP_JULIA="${HOME}/.juliaup/bin/julia"
STABLE_CHANNEL="1.13"

if [[ -n "${INSTALL_AGENT_TOOLS_DEPOT:-}" ]]; then
  DEPOT="${INSTALL_AGENT_TOOLS_DEPOT}"
else
  DEPOT="${HOME}/.julia"
fi
APPS_BIN="${DEPOT}/bin"
# App shims call `dirname`; keep a minimal PATH during install and health checks.
_TOOL_PATH="${APPS_BIN}:${HOME}/.juliaup/bin:/usr/local/bin:/usr/bin:/bin"

if [[ ! -x "${JULIAUP_JULIA}" ]]; then
  echo "install-agent-tools: missing ${JULIAUP_JULIA}" >&2
  exit 1
fi

jetls_rev="$(grep -E -m 1 -o 'rev="[0-9]{4}-[0-9]{2}-[0-9]{2}"' "${ACTION}" || true)"
jetls_rev="${jetls_rev#rev=\"}"
jetls_rev="${jetls_rev%\"}"
if [[ ! "${jetls_rev}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "install-agent-tools: no JETLS date pin in ${ACTION}" >&2
  exit 1
fi

mkdir -p "${APPS_BIN}"

link_into_path() {
  local name="$1"
  local source="${APPS_BIN}/${name}"
  local dest="/usr/local/bin/${name}"
  [[ -x "${source}" ]] || return 0
  if [[ -L "${dest}" ]] && [[ "$(readlink -f "${dest}")" == "$(readlink -f "${source}")" ]]; then
    return 0
  fi
  if [[ -e "${dest}" && ! -L "${dest}" ]]; then
    echo "install-agent-tools: refusing to replace non-symlink ${dest}" >&2
    return 0
  fi
  if [[ -w "$(dirname "${dest}")" ]]; then
    ln -sfn "${source}" "${dest}"
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    sudo -n ln -sfn "${source}" "${dest}"
  else
    echo "install-agent-tools: could not link ${dest} (no sudo)" >&2
  fi
}

app_works() {
  local name="$1"
  local bin="${APPS_BIN}/${name}"
  [[ -x "${bin}" ]] || return 1
  if [[ "${name}" == "runic" ]]; then
    JULIA_APPS_JULIA_CMD="${JULIAUP_JULIA}" PATH="${_TOOL_PATH}" \
      "${bin}" --version >/dev/null 2>&1
  else
    JULIA_APPS_JULIA_CMD="${JULIAUP_JULIA}" PATH="${_TOOL_PATH}" \
      "${bin}" version >/dev/null 2>&1
  fi
}

julia_apps() {
  JULIA_APPS_JULIA_CMD="${JULIAUP_JULIA}" \
    PATH="${_TOOL_PATH}" \
    JULIA_DEPOT_PATH="${DEPOT}" \
    "${JULIAUP_JULIA}" +"${STABLE_CHANNEL}" --startup-file=no -e "$1"
}

if app_works runic; then
  echo "install-agent-tools: runic already installed"
else
  echo "install-agent-tools: installing Runic"
  julia_apps 'using Pkg; Pkg.Apps.add("Runic")'
fi

if app_works jetls; then
  echo "install-agent-tools: jetls already installed"
else
  echo "install-agent-tools: installing JETLS rev=${jetls_rev}"
  julia_apps "using Pkg; Pkg.Apps.add(; url=\"https://github.com/aviatesk/JETLS.jl\", rev=\"${jetls_rev}\")"
fi

if ! app_works runic || ! app_works jetls; then
  echo "install-agent-tools: Runic or JETLS failed to install" >&2
  exit 1
fi

link_into_path runic
link_into_path jetls
echo "install-agent-tools: ok (depot=${DEPOT}, jetls_rev=${jetls_rev})"