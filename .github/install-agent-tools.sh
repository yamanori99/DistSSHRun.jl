#!/usr/bin/env bash
# Idempotent Runic + JETLS install for a VM, or for a person who chose to run it.
# An agent on a host machine does not run this unless the person asked.
# shellcheck is apt on Linux only.
# Runic pin: .github/runic/Project.toml [compat] (CI reads the same file). JETLS: jetls-check/action.yml.
# Julia 1.13 is `julia +1.13` on PATH, or a 1.13 julia already on PATH. No fixed install path.
#
# Optional INSTALL_AGENT_TOOLS_DEPOT: depot root for this script only (testing; no symlinks).
# Do not export HOME or JULIA_DEPOT_PATH; prefix Julia/Pkg calls when needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/section.sh
source "${ROOT}/scripts/section.sh"
ACTION="${ROOT}/.github/actions/jetls-check/action.yml"
RUNIC_COMPAT="${ROOT}/.github/runic/Project.toml"
RUNIC_UUID="62bfec6d-59d7-401d-8490-b29ee721c001"

runic_pin_from_compat() {
  sed -n -E 's/^Runic = "=([^"]+)".*/\1/p' "${RUNIC_COMPAT}" | head -1
}

die() {
  echo "install-agent-tools: error: $*" >&2
  exit 1
}

# Same discovery as scripts/check.sh.
JULIA=()
if command -v julia >/dev/null 2>&1 && julia +1.13 --startup-file=no -e 'exit(0)' >/dev/null 2>&1; then
  JULIA=(julia +1.13)
elif command -v julia >/dev/null 2>&1 && julia --startup-file=no -e 'exit(VERSION>=v"1.13" && VERSION<v"1.14" ? 0 : 1)' >/dev/null 2>&1; then
  JULIA=(julia)
else
  die "Julia 1.13 is not on PATH"
fi
JULIA_BIN="$("${JULIA[@]}" --startup-file=no -e 'print(joinpath(Sys.BINDIR, "julia"))')"
if [[ ! -x "${JULIA_BIN}" ]]; then
  die "Julia 1.13 binary is missing"
fi

if [[ -n "${INSTALL_AGENT_TOOLS_DEPOT:-}" ]]; then
  DEPOT="${INSTALL_AGENT_TOOLS_DEPOT}"
  LINK_TOOLS=false
else
  DEPOT="$("${JULIA[@]}" --startup-file=no -e 'print(DEPOT_PATH[1])')"
  LINK_TOOLS=true
fi
APPS_BIN="${DEPOT}/bin"
_TOOL_PATH="${APPS_BIN}:$(dirname "${JULIA_BIN}"):/usr/local/bin:/usr/bin:/bin"

if [[ ! -f "${RUNIC_COMPAT}" ]]; then
  die "missing ${RUNIC_COMPAT}"
fi
RUNIC_PIN="$(runic_pin_from_compat)"
if [[ ! "${RUNIC_PIN}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "invalid Runic compat pin in ${RUNIC_COMPAT}: ${RUNIC_PIN:-<empty>}"
fi

jetls_rev="$(grep -E -m 1 -o 'rev="[0-9]{4}-[0-9]{2}-[0-9]{2}"' "${ACTION}" || true)"
jetls_rev="${jetls_rev#rev=\"}"
jetls_rev="${jetls_rev%\"}"
if [[ ! "${jetls_rev}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  die "no JETLS date pin in ${ACTION}"
fi

mkdir -p "${APPS_BIN}"

if ! command -v shellcheck >/dev/null 2>&1 && [[ "$(uname -s)" == Linux ]]; then
  if ! sudo -n apt-get update; then
    die "apt-get update failed"
  fi
  if ! sudo -n apt-get install -y shellcheck; then
    die "apt-get install shellcheck failed"
  fi
  if ! command -v shellcheck >/dev/null 2>&1; then
    die "shellcheck not on PATH after install"
  fi
fi

link_into_path() {
  local name="$1"
  local source="${APPS_BIN}/${name}"
  local dest="/usr/local/bin/${name}"
  [[ -x "${source}" ]] || return 0
  if [[ -L "${dest}" ]] && [[ "$(readlink -f "${dest}")" == "$(readlink -f "${source}")" ]]; then
    return 0
  fi
  if [[ -e "${dest}" && ! -L "${dest}" ]]; then
    die "refusing to replace non-symlink ${dest}"
  fi
  if [[ -w "$(dirname "${dest}")" ]]; then
    ln -sfn "${source}" "${dest}"
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    sudo -n ln -sfn "${source}" "${dest}"
  else
    die "could not link ${dest} (no sudo)"
  fi
}

julia_tool() {
  JULIA_APPS_JULIA_CMD="${JULIA_BIN}" \
    PATH="${_TOOL_PATH}" \
    JULIA_DEPOT_PATH="${DEPOT}" \
    "${JULIA[@]}" --startup-file=no -e "$1"
}

runic_app_version() {
  local bin="${APPS_BIN}/runic"
  [[ -x "${bin}" ]] || return 1
  JULIA_APPS_JULIA_CMD="${JULIA_BIN}" PATH="${_TOOL_PATH}" \
    "${bin}" --version 2>/dev/null | sed -n 's/^runic version \([^,]*\).*/\1/p'
}

jetls_app_ok() {
  local bin="${APPS_BIN}/jetls"
  [[ -x "${bin}" ]] || return 1
  JULIA_APPS_JULIA_CMD="${JULIA_BIN}" PATH="${_TOOL_PATH}" \
    "${bin}" version >/dev/null 2>&1
}

jetls_manifest_ok() {
  local manifest="${DEPOT}/environments/apps/JETLS/Manifest.toml"
  [[ -f "${manifest}" ]] || return 1
  grep -q 'JETLSCore' "${manifest}"
}

runic_shared_ok() {
  julia_tool "
    using Pkg
    want = VersionNumber(\"${RUNIC_PIN}\")
    Pkg.activate(\"@runic\"; shared=true)
    try
      using Runic
    catch
      exit(1)
    end
    global pv = pkgversion(Runic)
    global ok_pin = false
    for (_, pkg) in Pkg.dependencies()
      if pkg.name == \"Runic\"
        global ok_pin = pkg.is_pinned
        global pv = pkg.version
        break
      end
    end
    exit((pv == want && ok_pin) ? 0 : 1)
  "
}

runic_app_at_pin() {
  local v
  v="$(runic_app_version || true)"
  [[ "${v}" == "${RUNIC_PIN}" ]]
}

runic_shared_at_pin() {
  runic_shared_ok
}

install_runic_app() {
  julia_tool "
    using Pkg
    Pkg.Apps.add(PackageSpec(
      name = \"Runic\",
      uuid = Base.UUID(\"${RUNIC_UUID}\"),
      version = VersionNumber(\"${RUNIC_PIN}\"),
    ))
  "
}

install_runic_shared() {
  julia_tool "
    using Pkg
    pin = VersionNumber(\"${RUNIC_PIN}\")
    Pkg.activate(\"@runic\"; shared=true)
    Pkg.add(PackageSpec(
      name = \"Runic\",
      uuid = Base.UUID(\"${RUNIC_UUID}\"),
      version = pin,
    ))
    Pkg.pin(PackageSpec(name = \"Runic\", version = pin))
    Pkg.precompile()
  "
}

section "install-agent-tools: runic ${RUNIC_PIN}"
if runic_app_at_pin; then
  echo "install-agent-tools: runic app already at ${RUNIC_PIN}"
else
  echo "install-agent-tools: installing Runic app ${RUNIC_PIN}"
  install_runic_app
fi

if runic_shared_at_pin; then
  echo "install-agent-tools: @runic already at ${RUNIC_PIN}"
else
  echo "install-agent-tools: installing Runic in @runic ${RUNIC_PIN}"
  install_runic_shared
fi
section "install-agent-tools: runic ok"

section "install-agent-tools: jetls ${jetls_rev}"
if jetls_app_ok && jetls_manifest_ok; then
  echo "install-agent-tools: jetls already installed (rev=${jetls_rev})"
else
  echo "install-agent-tools: installing JETLS rev=${jetls_rev}"
  julia_tool "using Pkg; Pkg.Apps.add(; url=\"https://github.com/aviatesk/JETLS.jl\", rev=\"${jetls_rev}\")"
fi

if ! jetls_app_ok; then
  die "jetls failed to start"
fi
section "install-agent-tools: jetls ok"

if [[ "${LINK_TOOLS}" == true && "$(uname -s)" == Linux ]]; then
  link_into_path runic
  link_into_path jetls
fi

runic_bin_ver="$(runic_app_version || true)"
shared_ver=""
shared_pin=""
if read -r shared_ver shared_pin < <(julia_tool "
  using Pkg
  Pkg.activate(\"@runic\"; shared=true)
  using Runic
  global pv = string(pkgversion(Runic))
  global pin_v = \"\"
  for (_, pkg) in Pkg.dependencies()
    if pkg.name == \"Runic\"
      global pin_v = pkg.is_pinned ? string(pkg.version) : \"\"
      global pv = string(pkg.version)
      break
    end
  end
  println(pv, \" \", pin_v)
"); then
  :
fi

if [[ "${runic_bin_ver}" != "${RUNIC_PIN}" ]] \
  || [[ "${shared_ver}" != "${RUNIC_PIN}" ]] \
  || [[ "${shared_pin}" != "${RUNIC_PIN}" ]]; then
  die "Runic versions differ: runic=${runic_bin_ver} @runic=${shared_ver} pin=${shared_pin}"
fi

if ! jetls_app_ok; then
  die "jetls failed final health check"
fi

section "install-agent-tools: ok"
echo "install-agent-tools: ok (depot=${DEPOT}, runic=${RUNIC_PIN}, jetls_rev=${jetls_rev})"
