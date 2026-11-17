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

# Pkg Apps shims pin a Julia binary. juliaup upgrades leave that path missing.
# The shim honors JULIA_APPS_JULIA_CMD; default to PATH `julia`, then juliaup.
if [[ -z "${JULIA_APPS_JULIA_CMD:-}" ]]; then
    if command -v julia >/dev/null 2>&1; then
        export JULIA_APPS_JULIA_CMD="$(command -v julia)"
    elif [[ -x "${HOME}/.juliaup/bin/julia" ]]; then
        export JULIA_APPS_JULIA_CMD="${HOME}/.juliaup/bin/julia"
    else
        echo "jetls-check: julia not found; set JULIA_APPS_JULIA_CMD to a julia binary" >&2
        exit 1
    fi
fi

_jetls_shim="${HOME}/.julia/bin/jetls"
_jetls_bin=""
if command -v jetls >/dev/null 2>&1; then
    _jetls_bin="$(command -v jetls)"
elif [[ -x "${_jetls_shim}" ]]; then
    _jetls_bin="${_jetls_shim}"
    PATH="${HOME}/.julia/bin:${PATH}"
    export PATH
fi

_jetls_pin_rev() {
    local action="${root}/.github/actions/jetls-check/action.yml"
    local rev=""
    rev="$(grep -E -m 1 -o 'rev="[0-9]{4}-[0-9]{2}-[0-9]{2}"' "${action}" 2>/dev/null || true)"
    rev="${rev#rev=\"}"
    rev="${rev%\"}"
    if [[ "${rev}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "${rev}"
    fi
}

if [[ -z "${_jetls_bin}" ]]; then
    echo "jetls-check: jetls not found (not on PATH and not ${HOME}/.julia/bin/jetls)" >&2
    echo "jetls-check: try one of:" >&2
    echo '  export PATH="$HOME/.julia/bin:$PATH"' >&2
    _pin="$(_jetls_pin_rev)"
    if [[ -n "${_pin}" ]]; then
        echo "  julia -e 'using Pkg; Pkg.Apps.add(; url=\"https://github.com/aviatesk/JETLS.jl\", rev=\"${_pin}\")'" >&2
    else
        echo '  julia -e '\''using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl")'\''' >&2
    fi
    echo "  ./.github/install-agent-tools.sh  # Cloud Agent / CI parity" >&2
    exit 1
fi

# Match .github/actions/jetls-check and aviatesk/JETLS.jl check@release: no
# `--threads=auto` (segfaults on Julia 1.13 in signature_analysis_worker).
exec "${_jetls_bin}" check --root=. --exit-severity=hint --show-severity=hint "${jetls_args[@]}" "${files[@]}"
