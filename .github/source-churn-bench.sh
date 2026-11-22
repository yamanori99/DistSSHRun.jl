#!/usr/bin/env bash
# Render source-churn metrics and publish to bench-data (main only).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ "${BENCH_PUSH:-0}" != "1" ] || [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || [ "${GITHUB_REF:-}" != "refs/heads/main" ]; then
    out="${RUNNER_TEMP:-/tmp}/churn-preview"
    rm -rf "$out"
    julia --startup-file=no --project=bench/compile bench/compile/churn_render.jl --out-dir "$out"
    echo "rendered churn preview at $out"
    exit 0
fi

token="${BENCH_TOKEN:?}"
dest="${RUNNER_TEMP:?}/bench-data"
rm -rf "$dest"
url="https://github.com/${GITHUB_REPOSITORY:?}.git"
basic="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
echo "::add-mask::${basic}"
auth=(-c "http.extraheader=AUTHORIZATION: basic ${basic}")
net=(-c http.connectTimeout=10 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30)
rc=0
git "${net[@]}" "${auth[@]}" ls-remote --exit-code --heads "$url" bench-data >/dev/null || rc=$?
if [ "$rc" = "2" ]; then
    git "${net[@]}" "${auth[@]}" clone --branch main --single-branch "$url" "$dest"
    git -C "$dest" checkout --orphan bench-data
    git -C "$dest" rm -rf . >/dev/null 2>&1 || true
elif [ "$rc" != "0" ]; then
    exit "$rc"
else
    git "${net[@]}" "${auth[@]}" clone --branch bench-data --single-branch "$url" "$dest"
fi
git -C "$dest" config http.extraheader "AUTHORIZATION: basic ${basic}"
julia --startup-file=no --project=bench/compile bench/compile/churn_render.jl \
    --out-dir "$dest/churn" \
    --append-readme "$dest/README.md"
git -C "$dest" config user.name "github-actions[bot]"
git -C "$dest" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$dest" add README.md churn/
if git -C "$dest" diff --cached --quiet; then
    echo "bench-data churn unchanged"
    exit 0
fi
git -C "$dest" commit -m "Render source churn."
for attempt in 1 2 3 4 5 6; do
    if git "${net[@]}" -C "$dest" push origin HEAD:bench-data; then
        exit 0
    fi
    git "${net[@]}" -C "$dest" pull --rebase origin bench-data || { git -C "$dest" rebase --abort || true; exit 1; }
    [ "$attempt" -lt 6 ] && sleep "$attempt"
done
git "${net[@]}" -C "$dest" push origin HEAD:bench-data