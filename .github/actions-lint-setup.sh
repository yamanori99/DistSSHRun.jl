#!/usr/bin/env bash
# Install or verify actionlint, zizmor, and pinact at the pins in actions-lint.env.
# CI sources this from actions-lint.yml; install-agent-tools.sh sources it on the VM.
# Set ACTIONS_LINT_GO_SYSTEM=1 to install the Go toolchain under /usr/local/go (CI).
# Otherwise the Go toolchain goes under GO_ROOT (default ~/.local/share/distsshrun-agent-tools/go).
set -euo pipefail

_actions_lint_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=actions-lint.env
source "${_actions_lint_here}/actions-lint.env"

actions_lint_die() {
  echo "actions-lint-setup: error: $*" >&2
  exit 1
}

actions_lint_bin_dir() {
  printf '%s\n' "${ACTIONS_LINT_BIN:-${HOME}/.local/bin}"
}

actions_lint_go_root() {
  printf '%s\n' "${GO_ROOT:-${HOME}/.local/share/distsshrun-agent-tools/go}"
}

actions_lint_install_go() {
  local go_ver go_sum go_archive go_root
  go_ver="${GO_VERSION}"
  go_sum="${GO_LINUX_AMD64_SHA256}"
  go_archive="$(mktemp "${TMPDIR:-/tmp}/go${go_ver}.linux-amd64.XXXXXX.tar.gz")"
  curl -fsSL --connect-timeout 30 --retry 8 --retry-all-errors \
    --retry-max-time 180 -o "${go_archive}" \
    "https://go.dev/dl/go${go_ver}.linux-amd64.tar.gz"
  echo "${go_sum}  ${go_archive}" | sha256sum -c - || actions_lint_die "Go ${go_ver} archive checksum mismatch"

  if [[ "${ACTIONS_LINT_GO_SYSTEM:-}" == 1 ]]; then
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "${go_archive}"
    rm -f "${go_archive}"
    export PATH="/usr/local/go/bin:${PATH}"
    return 0
  fi

  go_root="$(actions_lint_go_root)"
  rm -rf "${go_root}"
  mkdir -p "${go_root}"
  tar -C "${go_root}" --strip-components=1 -xzf "${go_archive}"
  rm -f "${go_archive}"
  export PATH="${go_root}/bin:${PATH}"
}

actions_lint_install_pip_prereqs() {
  if python3 -m pip --version >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$(uname -s)" != Linux ]]; then
    actions_lint_die "python3-pip is missing"
  fi
  if ! sudo -n apt-get update; then
    actions_lint_die "apt-get update failed (need python3-pip for zizmor)"
  fi
  if ! sudo -n apt-get install -y python3-pip; then
    actions_lint_die "apt-get install python3-pip failed"
  fi
  python3 -m pip --version >/dev/null 2>&1 || actions_lint_die "python3-pip not available after install"
}

actions_lint_tool_version_ok() {
  local name want out
  name="$1"
  want="$2"
  if ! command -v "${name}" >/dev/null 2>&1; then
    return 1
  fi
  case "${name}" in
    actionlint)
      out="$("${name}" -version 2>/dev/null | head -1)"
      [[ "${out}" == *"${want#v}"* ]]
      ;;
    pinact)
      local bin
      bin="$(command -v "${name}")"
      go version -m "${bin}" 2>/dev/null \
        | awk -v want="${want}" '$1 == "mod" && $2 == "github.com/suzuki-shunsuke/pinact/v5" && $3 == want { found = 1 } END { exit !found }'
      ;;
    zizmor)
      out="$("${name}" --version 2>/dev/null | head -1)"
      [[ "${out}" == *"${want}"* ]]
      ;;
    *)
      actions_lint_die "unknown tool ${name}"
      ;;
  esac
}

actions_lint_install_tools() {
  local bin_dir gopath
  bin_dir="$(actions_lint_bin_dir)"
  mkdir -p "${bin_dir}"
  export GOPATH="${GOPATH:-${TMPDIR:-/tmp}/distsshrun-gopath}"
  export GOBIN="${bin_dir}"
  mkdir -p "${GOPATH}"
  go_root="$(actions_lint_go_root)"
  if [[ -x "${go_root}/bin/go" ]]; then
    export PATH="${go_root}/bin:${GOBIN}:${HOME}/.local/bin:${PATH}"
  else
    export PATH="${GOBIN}:${HOME}/.local/bin:${PATH}"
  fi

  if ! command -v go >/dev/null 2>&1; then
    actions_lint_install_go
  elif ! go version | grep -q "go${GO_VERSION} "; then
    actions_lint_install_go
  fi

  if ! actions_lint_tool_version_ok actionlint "${ACTIONLINT_VERSION}"; then
    go install "github.com/rhysd/actionlint/cmd/actionlint@${ACTIONLINT_VERSION}"
  fi
  if ! actions_lint_tool_version_ok pinact "${PINACT_VERSION}"; then
    go install "github.com/suzuki-shunsuke/pinact/v5/cmd/pinact@${PINACT_VERSION}"
  fi

  actions_lint_install_pip_prereqs
  if ! actions_lint_tool_version_ok zizmor "${ZIZMOR_VERSION}"; then
    python3 -m pip install --user --break-system-packages "zizmor==${ZIZMOR_VERSION}"
  fi

  export PATH="${bin_dir}:${HOME}/.local/bin:${PATH}"
  actions_lint_tool_version_ok actionlint "${ACTIONLINT_VERSION}" \
    || actions_lint_die "actionlint not at ${ACTIONLINT_VERSION}"
  actions_lint_tool_version_ok pinact "${PINACT_VERSION}" \
    || actions_lint_die "pinact not at ${PINACT_VERSION}"
  actions_lint_tool_version_ok zizmor "${ZIZMOR_VERSION}" \
    || actions_lint_die "zizmor not at ${ZIZMOR_VERSION}"
}
