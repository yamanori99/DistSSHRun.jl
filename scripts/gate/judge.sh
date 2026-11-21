#!/usr/bin/env bash
# Judge CI job results after cheap guards. Set RESULT_<job_id> and DETECT_* env vars.
set -euo pipefail

fail() {
  echo "gate judge: $*" >&2
  exit 1
}

result_of() {
  local id="$1"
  local var="RESULT_${id}"
  echo "${!var:-missing}"
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

heavy="${DETECT_HEAVY:-true}"
scripts="${DETECT_SCRIPTS:-false}"
e2e="${DETECT_E2E:-false}"
base="${DETECT_BASE:-true}"
up="${DETECT_UP:-true}"
ship="${DETECT_SHIP:-true}"
heartbeat="${DETECT_HEARTBEAT:-true}"
queue_e2e="${DETECT_QUEUE_E2E:-false}"
coverage="${DETECT_COVERAGE:-false}"
event="${DETECT_EVENT:-pull_request}"
wsl_off="WSL jobs do not run on pull_request"
pkgeval_off="PkgEval does not run on pull_request"
nightly_off="nightly job does not run on pull_request"

heavy_off="detect heavy=false"
docs_scripts_off="heavy=${heavy} scripts=${scripts}"
e2e_off="detect e2e=false"
base_off="detect base=false"
up_off="detect up=false"
ship_off="detect ship=false"
heartbeat_off="detect heartbeat=false"
queue_off="detect queue_e2e=false"
coverage_off="detect coverage=false"

judge detect ""

judge runic "${docs_scripts_off}"
judge diff_lint_self_test "${docs_scripts_off}"

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
  judge downstream ""
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

judge base-test-ubuntu "${base_off}"
judge base-test-macos "${base_off}"
if [[ "${event}" == pull_request ]]; then
  judge base-test-wsl "${wsl_off}"
else
  judge base-test-wsl "${base_off}"
fi

judge up-test-ubuntu "${up_off}"
judge up-test-macos "${up_off}"
if [[ "${event}" == pull_request ]]; then
  judge up-test-wsl "${wsl_off}"
else
  judge up-test-wsl "${up_off}"
fi

judge ship-test-ubuntu "${ship_off}"
judge ship-test-macos "${ship_off}"
if [[ "${event}" == pull_request ]]; then
  judge ship-test-wsl "${wsl_off}"
else
  judge ship-test-wsl "${ship_off}"
fi

judge heartbeat-test-ubuntu "${heartbeat_off}"
judge heartbeat-test-macos "${heartbeat_off}"
if [[ "${event}" == pull_request ]]; then
  judge heartbeat-test-wsl "${wsl_off}"
else
  judge heartbeat-test-wsl "${heartbeat_off}"
fi

judge up-ssh-e2e "${e2e_off}"
judge base-ssh-e2e "${e2e_off}"
judge ship-ssh-e2e "${e2e_off}"
judge heartbeat-ssh-e2e "${e2e_off}"
judge ssh-e2e "${e2e_off}"
judge queue-ssh-e2e "${queue_off}"

# continue-on-error: failure does not fail gate when the job ran
for id in aqua-1-14-pre aqua-nightly jetls-1-14-pre ssh-e2e-1-14-pre; do
  r="$(result_of "${id}")"
  [[ "${r}" == skipped ]] && continue
  [[ "${r}" == success ]] && continue
  [[ "${r}" == failure ]] && printf 'note  %s failed (continue-on-error)\n' "${id}" && continue
  [[ "${r}" == cancelled ]] && fail "${id} cancelled"
  fail "${id} result=${r}"
done

echo "gate judge: ok"
