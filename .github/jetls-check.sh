#!/usr/bin/env bash
# Entry files for `jetls check` (hint+). JetLS follows top-level `include()`.
#
#   ./.github/jetls-check.sh
#   ./.github/jetls-check.sh --progress=none
#   ./.github/jetls-check.sh --print-files   # CI file list
#
# `test/e2e.jl` is a second test entry (not included from `runtests.jl`).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
shopt -s nullglob

files=(
    src/DistSSHRun.jl
    test/runtests.jl
    test/e2e.jl
    lib/DistSSHBase/test/runtests.jl
    lib/DistSSHUp/test/runtests.jl
    lib/DistSSHShip/test/runtests.jl
    lib/DistSSHHeartbeat/test/runtests.jl
    bench/compile/report.jl
    bench/compile/measure.jl
)

if ((${#files[@]} == 0)); then
    echo "jetls-check: no entry files matched" >&2
    exit 1
fi

print_files=false
jetls_args=()
for arg in "$@"; do
    if [[ "$arg" == "--print-files" ]]; then
        print_files=true
    else
        jetls_args+=("$arg")
    fi
done

if [[ "$print_files" == true ]]; then
    printf '%s\n' "${files[*]}"
    exit 0
fi

_jetls_depot() {
    local raw="${JULIA_DEPOT_PATH:-}"
    if [[ -n "${raw}" ]]; then
        local first="${raw%%:*}"
        if [[ -n "${first}" ]]; then
            echo "${first}"
            return 0
        fi
    fi
    if command -v julia >/dev/null 2>&1; then
        local depot=""
        if depot="$(julia +1.13 --startup-file=no -e 'print(DEPOT_PATH[1])' 2>/dev/null)" && [[ -n "${depot}" ]]; then
            echo "${depot}"
            return 0
        fi
        if depot="$(julia --startup-file=no -e 'print(DEPOT_PATH[1])' 2>/dev/null)" && [[ -n "${depot}" ]]; then
            echo "${depot}"
            return 0
        fi
    fi
    echo "${HOME}/.julia"
}

_jetls_pin_from_action() {
    local action="${root}/.github/actions/jetls-check/action.yml"
    local rev=""
    rev="$(grep -E -m 1 -o 'rev="[0-9]{4}-[0-9]{2}-[0-9]{2}"' "${action}" 2>/dev/null || true)"
    rev="${rev#rev=\"}"
    rev="${rev%\"}"
    if [[ "${rev}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "${rev}"
        return 0
    fi
    echo "error: JETLS pin is missing in ${action}" >&2
    exit 1
}

_jetls_installed_rev() {
    local manifest="$1"
    awk '
        /^\[\[deps\.JETLS\]\]/ { in_jetls = 1; next }
        /^\[\[deps\./ {
            if (in_jetls) {
                exit
            }
        }
        in_jetls && /^repo-rev = / {
            line = $0
            sub(/^repo-rev = /, "", line)
            gsub(/"/, "", line)
            print line
            exit
        }
    ' "${manifest}"
}

_pin="$(_jetls_pin_from_action)"
_depot="$(_jetls_depot)"
_apps_bin="${_depot}/bin"
_depot_jetls="${_apps_bin}/jetls"
_manifest="${_depot}/environments/apps/JETLS/Manifest.toml"

if [[ -n "${JULIA_APPS_JULIA_CMD:-}" ]]; then
    export JULIA_APPS_JULIA_CMD
elif ! command -v julia >/dev/null 2>&1; then
    {
        echo "error: julia is not on PATH (jetls needs it to start)"
        echo "install juliaup (https://julialang.org/downloads/) and open a new shell, or set:"
        echo "  export JULIA_APPS_JULIA_CMD=/path/to/julia"
        echo "then rerun ./.github/jetls-check.sh"
    } >&2
    exit 1
fi

_path_jetls=""
if command -v jetls >/dev/null 2>&1; then
    _path_jetls="$(command -v jetls)"
elif [[ -x "${_depot_jetls}" ]]; then
    _path_jetls="${_depot_jetls}"
fi

if [[ -z "${_path_jetls}" ]]; then
    {
        echo "error: jetls is not installed (looked on PATH and ${_depot_jetls})"
        echo "install the pinned release (${_pin}, from .github/actions/jetls-check/action.yml):"
        echo "  ./.github/install-agent-tools.sh"
        echo "then rerun ./.github/jetls-check.sh"
    } >&2
    exit 1
fi

_installed="unknown"
if [[ -f "${_manifest}" ]] && [[ -r "${_manifest}" ]]; then
    _got="$(_jetls_installed_rev "${_manifest}")"
    if [[ -n "${_got}" ]]; then
        _installed="${_got}"
    fi
else
    _installed="unknown"
fi

if [[ "${_installed}" != "${_pin}" ]]; then
    {
        echo "error: jetls ${_installed} is installed, but this repo pins ${_pin} (CI uses the pin)"
        echo "installed rev read from ${_manifest}; update with:"
        echo "  ./.github/install-agent-tools.sh"
        echo "then rerun ./.github/jetls-check.sh"
    } >&2
    exit 1
fi

# Match .github/actions/jetls-check and aviatesk/JETLS.jl check@release: no
# `--threads=auto` (segfaults on Julia 1.13 in signature_analysis_worker).
exec "${_path_jetls}" check --root=. --exit-severity=hint --show-severity=hint "${jetls_args[@]}" "${files[@]}"
