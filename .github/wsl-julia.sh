#!/usr/bin/env bash
# Julia inside WSL2. The caller is wsl-bash and cwd is the Actions checkout.
# The workflow's actions/cache restores .ci-cache/wsl-julia (one channel per key).
#
#   ./.github/wsl-julia.sh <juliaup-channel> <command...>
#   ./.github/wsl-julia.sh '~1.14.0-0' <command...>
#
# A leading `~` is a setup-julia tilde range, not a juliaup channel.
# juliaup treats `~` as an architecture suffix, so this script resolves
# `~1.14.0-0` against versions.json first (>= that 1.14.0 prerelease,
# <1.15.0, including later 1.14 stables, excluding other 1.14 prereleases).
set -euo pipefail

# Ubuntu-24.04's WSL rootfs usually has these. Install only when it does not,
# so Vampire/setup-wsl does not apt-get on every job.
ensure_curl_git() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v git >/dev/null 2>&1 || missing+=(git)
  [[ ${#missing[@]} -eq 0 ]] && return 0
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "WSL image is missing ${missing[*]}; need root to install" >&2
    return 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  timeout 180 apt-get update -qq
  timeout 180 apt-get install -y --no-install-recommends ca-certificates "${missing[@]}"
}

# Sort key for one versions.json version. Unrecognized names return 1.
tilde_sort_key() {
  local ver="$1" rank
  if [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    printf '%05d%05d%05d%d%05d\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" 3 0
    return 0
  fi
  if [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-(alpha|beta|rc)([0-9]+)$ ]]; then
    case "${BASH_REMATCH[4]}" in
      alpha) rank=0 ;;
      beta) rank=1 ;;
      rc) rank=2 ;;
    esac
    printf '%05d%05d%05d%d%05d\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "$rank" "${BASH_REMATCH[5]}"
    return 0
  fi
  return 1
}

# setup-julia `~M.N.P-0`: same major.minor, patch >= P when stable, and
# prereleases only of that exact patch. 1.14.1-rc1 does not match ~1.14.0-0.
matches_tilde_range() {
  local ver="$1" major="$2" minor="$3" patch="$4"
  if [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    [[ "${BASH_REMATCH[1]}" == "$major" && "${BASH_REMATCH[2]}" == "$minor" && "${BASH_REMATCH[3]}" -ge "$patch" ]]
    return
  fi
  if [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-(alpha|beta|rc)[0-9]+$ ]]; then
    [[ "${BASH_REMATCH[1]}" == "$major" && "${BASH_REMATCH[2]}" == "$minor" && "${BASH_REMATCH[3]}" == "$patch" ]]
    return
  fi
  return 1
}

resolve_setup_julia_tilde() {
  local spec="$1" major minor patch json line ver key best best_key
  if [[ ! "$spec" =~ ^~([0-9]+)\.([0-9]+)\.([0-9]+)-0$ ]]; then
    echo "unsupported setup-julia range: ${spec}" >&2
    return 1
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  json="$(mktemp)"
  curl --retry 5 --retry-delay 5 --retry-connrefused --connect-timeout 10 \
    -fsSL -o "$json" https://julialang-s3.julialang.org/bin/versions.json \
    || { rm -f "$json"; echo "failed to download versions.json" >&2; return 1; }
  best=""
  best_key=""
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*\"([0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*)\"[[:space:]]*: ]] || continue
    ver="${BASH_REMATCH[1]}"
    key="$(tilde_sort_key "$ver")" || continue
    matches_tilde_range "$ver" "$major" "$minor" "$patch" || continue
    if [[ -z "$best" || "$key" > "$best_key" ]]; then
      best="$ver"
      best_key="$key"
    fi
  done < "$json"
  rm -f "$json"
  if [[ -z "$best" ]]; then
    echo "no Julia version matches ${spec}" >&2
    return 1
  fi
  printf '%s\n' "$best"
}

channel="$1"
shift
ensure_curl_git

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
# Checkout on /mnt is owned by root. `git -c` does not reach the
# ownership check inside clone, so record it for this user.
git config --global --add safe.directory '*'
git clone "$src" "$dest"
install_channel="$channel"
if [[ "$channel" == \~* ]]; then
  install_channel="$(resolve_setup_julia_tilde "$channel")"
  echo "setup-julia ${channel} resolved to ${install_channel}"
fi
# juliaup does not retry its own download of a nightly tarball. The curl
# retries cover only https://install.julialang.org.
install_julia() {
  local attempt
  for attempt in 1 2 3; do
    rm -rf "$HOME/.juliaup" "$HOME/.julia"
    if curl --retry 5 --retry-delay 5 --retry-connrefused --connect-timeout 10 \
      -fsSL https://install.julialang.org | sh -s -- --yes --default-channel "$install_channel"
    then
      return 0
    fi
    echo "Julia install attempt ${attempt} failed" >&2
    sleep $((attempt * 10))
  done
  echo "Julia install failed after 3 attempts" >&2
  return 1
}
restored=0
if [[ -f "$cache/julia.tgz" ]]; then
  tar -xzf "$cache/julia.tgz" -C "$HOME"
  restored=1
else
  install_julia
fi
export PATH="$HOME/.juliaup/bin:$PATH"
# A cache hit would keep the first build. Move a nightly channel forward.
# A tilde range is an exact version after resolution, so add that version.
if [[ "$restored" -eq 1 && ( "$channel" == "nightly" || "$channel" == *-nightly ) ]]; then
  juliaup update "$channel"
elif [[ "$restored" -eq 1 && "$channel" == \~* ]]; then
  juliaup add "$install_channel"
  juliaup default "$install_channel"
fi
cd "$dest"
"$@"
if [[ -d "$HOME/.julia" ]]; then
  tar -czf "$cache/julia.tgz" -C "$HOME" .juliaup .julia
else
  tar -czf "$cache/julia.tgz" -C "$HOME" .juliaup
fi
