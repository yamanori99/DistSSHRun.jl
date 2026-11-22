#!/usr/bin/env bash
# Render the source-churn report into a directory.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
out=""
readme=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out-dir) out="$2"; shift 2 ;;
        --append-readme) readme="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$out" ] || { echo "missing --out-dir" >&2; exit 2; }
args=(--out-dir "$out")
[ -n "$readme" ] && args+=(--append-readme "$readme")
julia --startup-file=no --project=bench/compile bench/compile/churn_render.jl "${args[@]}"
