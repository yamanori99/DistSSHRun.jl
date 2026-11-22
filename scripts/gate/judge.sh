#!/usr/bin/env bash
# Judge CI job results after cheap guards. Set RESULT_<job_id> and DETECT_* env vars.
set -euo pipefail

fail() {
  echo "gate judge: $*" >&2
  exit 1
}

result_of() {
  local id="$1"
  local norm="${id//-/_}"
  local var="RESULT_${norm}"
  echo "${!var:-missing}"
}

# Nonempty allow_skip_reason permits a skipped job. Pass "" when the job must run.
skip_unless() {
  local flag="$1"
  local reason="$2"
  [[ "${flag}" == true ]] && echo "" || echo "${reason}"
}

judge() {
  local id="$1"
  local allow_skip_reason="${2:-}"
  local r
  r="$(result_of "${id}")"
  case "${r}" in
    success) return 0 ;;
    skipped)
      if [[ -z "${allow_skip_reason}" ]]; then
        fail "${id} skipped (no allowed reason)"
      fi
      printf 'note  allowed skip %s: %s\n' "${id}" "${allow_skip_reason}"
      ;;
    cancelled) fail "${id} cancelled" ;;
    failure|missing) fail "${id} result=${r}" ;;
    *) fail "${id} unknown result=${r}" ;;
  esac
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=judge_matrix.sh
source "${ROOT}/scripts/gate/judge_matrix.sh"

heavy="${DETECT_HEAVY:-true}"
scripts="${DETECT_SCRIPTS:-false}"
e2e="${DETECT_E2E:-false}"
base="${DETECT_BASE:-true}"
up="${DETECT_UP:-true}"
ship="${DETECT_SHIP:-true}"
heartbeat="${DETECT_HEARTBEAT:-true}"
testenv="${DETECT_TESTENV:-false}"
queue_e2e="${DETECT_QUEUE_E2E:-false}"
coverage="${DETECT_COVERAGE:-false}"
event="${DETECT_EVENT:-pull_request}"
wsl_off="WSL jobs do not run on pull_request"
pkgeval_off="PkgEval does not run on pull_request"
nightly_off="nightly job does not run on pull_request"

heavy_off="detect heavy=${heavy}"
docs_scripts_off="heavy=${heavy} scripts=${scripts}"
e2e_off="detect e2e=${e2e}"
base_off="detect base=${base}"
up_off="detect up=${up}"
ship_off="detect ship=${ship}"
heartbeat_off="detect heartbeat=${heartbeat}"
queue_off="detect queue_e2e=${queue_e2e}"
coverage_off="detect coverage=false"

judge detect ""

if [[ "${heavy}" == true || "${scripts}" == true ]]; then
  judge runic ""
else
  judge runic "${docs_scripts_off}"
fi
if [[ "${scripts}" == true ]]; then
  judge diff_lint_self_test ""
else
  judge diff_lint_self_test "${docs_scripts_off}"
fi

if [[ "${heavy}" == true ]]; then
  judge jetls ""
  judge aqua ""
  judge test-unit ""
  judge test-integration ""
  judge test-macos-unit ""
  judge test-macos-integration ""
  judge registry-install ""
  judge test-1-14-pre-unit ""
  judge test-1-14-pre-integration ""
  judge test-1-14-pre-macos-unit ""
  judge test-1-14-pre-macos-integration ""
  if [[ "${coverage}" == true ]]; then
    judge test-coverage ""
  else
    judge test-coverage "${coverage_off}"
  fi
  if [[ "${event}" == pull_request ]]; then
    judge test-wsl "${wsl_off}"
  else
    judge test-wsl ""
  fi
  if [[ "${event}" == pull_request ]]; then
    judge test-nightly "${nightly_off}"
    judge pkgeval "${pkgeval_off}"
  else
    judge test-nightly ""
    judge pkgeval ""
  fi
else
  for id in jetls aqua test-unit test-integration test-macos-unit test-macos-integration \
    registry-install test-1-14-pre-unit test-1-14-pre-integration test-1-14-pre-macos-unit \
    test-1-14-pre-macos-integration downstream test-coverage pkgeval; do
    judge "${id}" "${heavy_off}"
  done
  judge test-wsl "${heavy_off}"
  judge test-nightly "${heavy_off}"
fi

package_detect_off() {
  local flag_off="$1"
  if [[ "${heavy}" != true ]]; then
    echo "${heavy_off}"
  else
    echo "${flag_off}"
  fi
}

judge_when_detect base-test-ubuntu "$(pkg_should_run "${base}" && echo true || echo false)" "$(package_detect_off "${base_off}")"
judge_when_detect base-test-macos "$(pkg_should_run "${base}" && echo true || echo false)" "$(package_detect_off "${base_off}")"
if [[ "${event}" == pull_request ]]; then
  judge base-test-wsl "${wsl_off}"
else
  judge_when_detect base-test-wsl "$(pkg_should_run "${base}" && echo true || echo false)" "$(package_detect_off "${base_off}")"
fi

judge_when_detect up-test-ubuntu "$(pkg_should_run "${up}" && echo true || echo false)" "$(package_detect_off "${up_off}")"
judge_when_detect up-test-macos "$(pkg_should_run "${up}" && echo true || echo false)" "$(package_detect_off "${up_off}")"
if [[ "${event}" == pull_request ]]; then
  judge up-test-wsl "${wsl_off}"
else
  judge_when_detect up-test-wsl "$(pkg_should_run "${up}" && echo true || echo false)" "$(package_detect_off "${up_off}")"
fi

judge_when_detect ship-test-ubuntu "$(pkg_should_run "${ship}" && echo true || echo false)" "$(package_detect_off "${ship_off}")"
judge_when_detect ship-test-macos "$(pkg_should_run "${ship}" && echo true || echo false)" "$(package_detect_off "${ship_off}")"
if [[ "${event}" == pull_request ]]; then
  judge ship-test-wsl "${wsl_off}"
else
  judge_when_detect ship-test-wsl "$(pkg_should_run "${ship}" && echo true || echo false)" "$(package_detect_off "${ship_off}")"
fi

judge_when_detect heartbeat-test-ubuntu "$(pkg_should_run "${heartbeat}" && echo true || echo false)" "$(package_detect_off "${heartbeat_off}")"
judge_when_detect heartbeat-test-macos "$(pkg_should_run "${heartbeat}" && echo true || echo false)" "$(package_detect_off "${heartbeat_off}")"
if [[ "${event}" == pull_request ]]; then
  judge heartbeat-test-wsl "${wsl_off}"
else
  judge_when_detect heartbeat-test-wsl "$(pkg_should_run "${heartbeat}" && echo true || echo false)" "$(package_detect_off "${heartbeat_off}")"
fi

judge_when_detect up-ssh-e2e "$(e2e_up_should_run && echo true || echo false)" "${e2e_off}"
judge_when_detect base-ssh-e2e "$(e2e_base_should_run && echo true || echo false)" "${e2e_off}"
judge_when_detect ship-ssh-e2e "$(e2e_ship_should_run && echo true || echo false)" "${e2e_off}"
judge_when_detect heartbeat-ssh-e2e "$(e2e_heartbeat_should_run && echo true || echo false)" "${e2e_off}"
judge_when_detect ssh-e2e "$(e2e_run_should_run && echo true || echo false)" "${e2e_off}"
judge_when_detect queue-ssh-e2e "$(queue_e2e_should_run && echo true || echo false)" "${queue_off}"

# continue-on-error: failure does not fail gate when the job ran
for id in aqua-1-14-pre aqua-nightly jetls-1-14-pre ssh-e2e-1-14-pre downstream; do
  r="$(result_of "${id}")"
  [[ "${r}" == skipped ]] && continue
  [[ "${r}" == success ]] && continue
  [[ "${r}" == failure ]] && printf 'note  %s failed (continue-on-error)\n' "${id}" && continue
  [[ "${r}" == cancelled ]] && fail "${id} cancelled"
  fail "${id} result=${r}"
done

echo "gate judge: ok"
