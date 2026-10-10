#!/usr/bin/env bash
# Julia inside WSL2. The caller is wsl-bash and cwd is the Actions checkout.
# The workflow's actions/cache restores .ci-cache/wsl-julia (one channel per key).
#
#   ./.github/wsl-julia.sh <juliaup-channel> <command...>
set -euo pipefail

channel="$1"
shift

# The Actions distro is root. chmod does not deny that user, so a test
# that locks a directory still writes into it. Run the rest as `ci`.
if [[ "$(id -u)" -eq 0 ]]; then
  if ! id -u ci >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash ci
  fi
  src="$(pwd)"
  mkdir -p "$src/.ci-cache/wsl-julia"
  chmod -R a+rX "$src"
  chmod 777 "$src/.ci-cache" "$src/.ci-cache/wsl-julia"
  exec runuser -u ci -- "$0" "$channel" "$@"
fi

src="$(pwd)"
dest="$HOME/DistSSHRun.jl"
cache="$src/.ci-cache/wsl-julia"
mkdir -p "$cache"
rm -rf "$dest"
git clone "$src" "$dest"
if [[ -f "$cache/julia.tgz" ]]; then
  tar -xzf "$cache/julia.tgz" -C "$HOME"
else
  curl --retry 5 --retry-delay 5 --retry-connrefused --connect-timeout 10 \
    -fsSL https://install.julialang.org | sh -s -- --yes --default-channel "$channel"
fi
export PATH="$HOME/.juliaup/bin:$PATH"
cd "$dest"
"$@"
if [[ -d "$HOME/.julia" ]]; then
  tar -czf "$cache/julia.tgz" -C "$HOME" .juliaup .julia
else
  tar -czf "$cache/julia.tgz" -C "$HOME" .juliaup
fi
