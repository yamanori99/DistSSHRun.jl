# shellcheck shell=bash
# Retry a step that downloads Julia or juliaup. Sourced, not executed.
#
# juliaup fetches its version db from julialang-s3 after the installer
# download, and `curl --retry` does not cover that request.
#
#   DISTSSHKIT_BUILD_RETRIES     attempts, default 3 (1 disables retry)
#   DISTSSHKIT_BUILD_RETRY_WAIT  first wait in seconds, default 30; doubles

_distsshkit_retry() {
  local what="$1"
  shift
  local tries="${DISTSSHKIT_BUILD_RETRIES:-3}"
  local wait_s="${DISTSSHKIT_BUILD_RETRY_WAIT:-30}"
  local i
  for ((i = 1; ; i++)); do
    if "$@"; then
      return 0
    fi
    if ((i >= tries)); then
      echo "${what} failed after ${tries} attempts" >&2
      return 1
    fi
    echo "${what} failed (${i}/${tries}); retrying in ${wait_s}s" >&2
    sleep "${wait_s}"
    wait_s=$((wait_s * 2))
  done
}

# Fresh juliaup install with the default channel. Removes a partial
# ~/.juliaup from an earlier failed attempt first.
_distsshkit_install_juliaup() {
  local channel="$1"
  rm -rf "$HOME/.juliaup"
  curl --retry 5 --retry-delay 5 --retry-connrefused --connect-timeout 10 \
    -fsSL https://install.julialang.org | sh -s -- --yes --default-channel "${channel}"
}
