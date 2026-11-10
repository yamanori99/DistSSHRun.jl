#!/usr/bin/env bash
# Guard in-repo lib packages: versions lockstep with DistSSHRun and = compat pins.
#
#   ./.github/lib-lockstep-check.sh
#   ./.github/lib-lockstep-check.sh --self-test
#   ./.github/lib-lockstep-check.sh --base REF   # also enforce bump / realignment rules
#
# Intra-repo [compat] on sibling libs uses "=" plus the numeric triple from Run's
# version (prerelease stripped). Julia Pkg rejects "=0.2.0-DEV" (invalid version
# specifier); "=0.2.0" resolves path deps at 0.2.0-DEV and stays "=0.2.0" after cut.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

VERSION_FILES=(
  Project.toml
  lib/DistSSHBase/Project.toml
  lib/DistSSHUp/Project.toml
  lib/DistSSHShip/Project.toml
  lib/DistSSHHeartbeat/Project.toml
)

COMPAT_FILES=(
  lib/DistSSHUp/Project.toml
  lib/DistSSHShip/Project.toml
  lib/DistSSHHeartbeat/Project.toml
  lib/DistSSHBase/test/Project.toml
  lib/DistSSHUp/test/Project.toml
  lib/DistSSHShip/test/Project.toml
  lib/DistSSHHeartbeat/test/Project.toml
)

INREPO_PACKAGES=(DistSSHBase DistSSHUp DistSSHShip DistSSHHeartbeat)

ver_from_file() {
  sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}

# Numeric x.y.z from a version string (drop prerelease after first hyphen).
version_triple() {
  local v="$1"
  v="${v%%-*}"
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$v" ;;
    *)
      echo "unsupported version ${1}" >&2
      return 1
      ;;
  esac
}

compat_pin_for_run() {
  printf '=%s\n' "$(version_triple "$1")"
}

compat_line_value() {
  local file="$1" pkg="$2"
  awk -v pkg="$pkg" '
    /^\[compat\]/ { incompat = 1; next }
    /^\[/ { incompat = 0 }
    incompat && $0 ~ "^" pkg "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*"/, "")
      sub(/"$/, "")
      print
      exit
    }
  ' "$file"
}

check_versions() {
  local run_ver="$1" failed=0 f lib_ver
  for f in "${VERSION_FILES[@]}"; do
    lib_ver="$(ver_from_file "$f")"
    if [ "$lib_ver" != "$run_ver" ]; then
      echo "lockstep: ${f} version ${lib_ver} != DistSSHRun ${run_ver}" >&2
      failed=1
    fi
  done
  return "$failed"
}

check_compat_pins() {
  local run_ver="$1" want failed=0 f pkg val
  want="$(compat_pin_for_run "$run_ver")"
  for f in "${COMPAT_FILES[@]}"; do
    for pkg in "${INREPO_PACKAGES[@]}"; do
      val="$(compat_line_value "$f" "$pkg" || true)"
      [ -z "$val" ] && continue
      if [ "$val" != "$want" ]; then
        echo "lockstep: ${f} ${pkg} = \"${val}\" want \"${want}\" (Run ${run_ver})" >&2
        failed=1
      fi
    done
  done
  return "$failed"
}

base_has_drift() {
  local base="$1" run_ver f v
  run_ver="$(git show "${base}:Project.toml" | ver_from_file /dev/stdin)"
  for f in lib/DistSSHBase/Project.toml lib/DistSSHUp/Project.toml lib/DistSSHShip/Project.toml lib/DistSSHHeartbeat/Project.toml; do
    v="$(git show "${base}:${f}" | ver_from_file /dev/stdin)"
    if [ "$v" != "$run_ver" ]; then
      return 0
    fi
  done
  return 1
}

version_lines_changed() {
  local base="$1" head="$2"
  git diff --unified=0 "$base" "$head" -- "${VERSION_FILES[@]}" \
    | grep -E '^[-+][^-+].*^[[:space:]]*version[[:space:]]*=' || return 1
}

compat_lines_changed() {
  local base="$1" head="$2"
  git diff --unified=0 "$base" "$head" -- "${COMPAT_FILES[@]}" \
    | grep -E '^[-+][^-+].*^(DistSSH(Base|Up|Ship|Heartbeat))[[:space:]]*=' || return 1
}

check_diff_policy() {
  local base="$1" head="$2"
  local old_run new_run cut_ok
  old_run="$(git show "${base}:Project.toml" | ver_from_file /dev/stdin)"
  new_run="$(ver_from_file Project.toml)"
  cut_ok=false
  if [ -x "$root/.github/version-cut.sh" ]; then
  if [ "$(bash "$root/.github/version-cut.sh" --versions "$old_run" "$new_run")" = true ]; then
      cut_ok=true
    fi
  fi

  if version_lines_changed "$base" "$head"; then
    if $cut_ok; then
      return 0
    fi
    if base_has_drift "$base" && check_versions "$new_run"; then
      # One-time realignment: libs caught up to an unchanged Run version.
      if [ "$old_run" = "$new_run" ]; then
        return 0
      fi
    fi
    echo "lockstep: version lines changed without a release cut (was ${old_run}, now ${new_run})" >&2
    echo "lockstep: use .github/version-cut.sh --lockstep-write after bumping Run version" >&2
    return 1
  fi

  if compat_lines_changed "$base" "$head"; then
    if $cut_ok; then
      return 0
    fi
    if base_has_drift "$base"; then
      return 0
    fi
    echo "lockstep: in-repo sibling [compat] changed outside a release cut or drift realignment" >&2
    return 1
  fi
  return 0
}

self_test() {
  local failed=0 want

  want="$(compat_pin_for_run 0.2.0-DEV)"
  if [ "$want" != "=0.2.0" ]; then
    echo "FAIL compat_pin 0.2.0-DEV want =0.2.0 got ${want}" >&2
    failed=1
  fi
  want="$(compat_pin_for_run 0.2.0)"
  if [ "$want" != "=0.2.0" ]; then
    echo "FAIL compat_pin 0.2.0 want =0.2.0 got ${want}" >&2
    failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    exit 1
  fi
  echo "lib-lockstep-check self-test ok"
}

main() {
  if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit 0
  fi

  local base=""
  if [ "${1:-}" = "--base" ]; then
    base="${2:?base ref}"
    shift 2
  fi

  local run_ver failed=0
  run_ver="$(ver_from_file Project.toml)"
  if [ -z "$run_ver" ]; then
    echo "lockstep: no version in Project.toml" >&2
    exit 1
  fi

  check_versions "$run_ver" || failed=1
  check_compat_pins "$run_ver" || failed=1

  if [ -n "$base" ]; then
    git rev-parse --verify "${base}^{commit}" >/dev/null
    check_diff_policy "$base" HEAD || failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    exit 1
  fi
  echo "lib-lockstep ok (Run ${run_ver})"
}

main "$@"
