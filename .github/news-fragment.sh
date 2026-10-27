#!/usr/bin/env bash
# Pull requests that do not cut a version:
# - a change under src/**, lib/**/src/**, or ext/** needs one valid fragment
# - Dependabot is exempt
# - the breaking label and a category: breaking fragment require each other
# Planned fragments do not require the breaking label. A version cut does
# not run this script.
#
# Usage:
#   ./.github/news-fragment.sh OLD_REF NEW_REF
#   ./.github/news-fragment.sh --self-test
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

die() {
  echo "news-fragment: $*" >&2
  return 1
}

path_needs_fragment() {
  local path="$1"
  case "$path" in
    src/* | ext/*) return 0 ;;
    lib/*)
      case "$path" in
        */src/*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

is_fragment_path() {
  local path="$1" base
  case "$path" in
    changelog.d/*) ;;
    *) return 1 ;;
  esac
  base="${path#changelog.d/}"
  case "$base" in
    */*) return 1 ;;
    *.md) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_commit() {
  local ref="$1"
  git cat-file -e "${ref}^{commit}" 2>/dev/null && return 0
  if ! git fetch --depth=1 origin "$ref"; then
    if [[ -n "${PR:-}" ]]; then
      git fetch --depth=1 origin "refs/pull/${PR}/head" || true
    fi
  fi
  git cat-file -e "${ref}^{commit}"
}

# Print need, fragments, and breaking counts for the diff.
scan_diff() {
  local old="$1" new="$2"
  local need=false fragments=0 breaking=0
  local status p1 p2 path dest category dir
  while IFS=$'\t' read -r status p1 p2; do
    [[ -z "${status:-}" ]] && continue
    case "$status" in
      R* | C*)
        path_needs_fragment "$p1" && need=true
        path_needs_fragment "$p2" && need=true
        path="$p2"
        ;;
      D)
        path_needs_fragment "$p1" && need=true
        continue
        ;;
      *)
        path_needs_fragment "$p1" && need=true
        path="$p1"
        ;;
    esac
    if is_fragment_path "$path"; then
      dir="$(mktemp -d)"
      dest="$dir/$(basename "$path")"
      git cat-file -p "$new:$path" >"$dest"
      if ! category="$("$here/news-collect.sh" --validate "$dest")"; then
        rm -rf "$dir"
        return 1
      fi
      rm -rf "$dir"
      fragments=$((fragments + 1))
      if [[ "$category" == breaking ]]; then
        breaking=$((breaking + 1))
      fi
    elif [[ "$path" == changelog.d/* ]]; then
      die "${path} is not a fragment file"
      return 1
    fi
  done < <(git -c core.quotePath=false diff --name-status --find-renames "$old" "$new")
  printf 'need=%s\nfragments=%s\nbreaking=%s\n' "$need" "$fragments" "$breaking"
}

decide() {
  local dependabot="$1" need="$2" label="$3" fragments="$4" breaking="$5"
  if [[ "$dependabot" == true ]]; then
    echo "Dependabot: fragment check skipped"
    return 0
  fi
  if [[ "$need" == true && "$fragments" -lt 1 ]]; then
    die "changes under src/, lib/**/src/, or ext/ need a changelog.d fragment"
    return 1
  fi
  if [[ "$label" == true && "$breaking" -lt 1 ]]; then
    die "breaking label requires a fragment with category: breaking"
    return 1
  fi
  if [[ "$breaking" -gt 0 && "$label" != true ]]; then
    die "category: breaking requires the breaking label"
    return 1
  fi
  echo "news-fragment: ok"
}

fetch_breaking_label() {
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}" name found=false names
  if [[ -z "$token" || -z "${GITHUB_REPOSITORY:-}" || -z "${PR:-}" ]]; then
    die "missing GH_TOKEN, GITHUB_REPOSITORY, or PR"
    return 1
  fi
  if ! names="$(gh api --jq '.labels[].name' "repos/${GITHUB_REPOSITORY}/issues/${PR}")"; then
    die "could not read pull request labels"
    return 1
  fi
  while IFS= read -r name; do
    if [[ "$name" == breaking ]]; then
      found=true
    fi
  done <<<"$names"
  printf '%s\n' "$found"
}

self_test() {
  local tmp failed=0 repo base head facts need fragments breaking
  tmp="$(mktemp -d)"
  fail() {
    echo "FAIL $*" >&2
    failed=1
  }
  repo="$tmp/repo"
  mkdir -p "$repo/src" "$repo/lib/DistSSHBase/src" "$repo/ext" "$repo/changelog.d" "$repo/docs"
  git -C "$repo" init -q
  git -C "$repo" config user.email "news-fragment@example.com"
  git -C "$repo" config user.name "news-fragment"
  git -C "$repo" config commit.gpgsign false
  printf 'name = "Example"\nversion = "0.1.0"\n' >"$repo/Project.toml"
  printf 'base\n' >"$repo/src/a.jl"
  git -C "$repo" add Project.toml src
  git -C "$repo" commit -q -m base
  base="$(git -C "$repo" rev-parse HEAD)"

  if ! decide true true false 0 0 | grep -q 'Dependabot'; then
    fail "dependabot"
  fi
  if decide false true false 0 0 >/dev/null 2>"$tmp/err"; then
    fail "src without fragment"
  fi
  if ! decide false true false 1 0 >/dev/null; then
    fail "src with fragment"
  fi
  if decide false false false 1 1 >/dev/null 2>"$tmp/err"; then
    fail "breaking fragment without label"
  fi
  if decide false false true 0 0 >/dev/null 2>"$tmp/err"; then
    fail "label without fragment"
  fi
  if ! decide false false true 1 1 >/dev/null; then
    fail "breaking pair"
  fi
  if ! decide false false false 1 0 >/dev/null; then
    fail "planned or fixed without label"
  fi

  printf 'docs\n' >"$repo/docs/a.md"
  git -C "$repo" add docs
  git -C "$repo" commit -q -m docs
  head="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$head")"
  need="$(printf '%s\n' "$facts" | sed -n 's/^need=//p')"
  fragments="$(printf '%s\n' "$facts" | sed -n 's/^fragments=//p')"
  if [[ "$need" != false || "$fragments" != 0 ]]; then
    fail "docs-only scan: ${facts}"
  fi

  printf 'lib\n' >"$repo/lib/DistSSHBase/src/a.jl"
  git -C "$repo" add lib
  git -C "$repo" commit -q -m lib
  head="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$head")"
  need="$(printf '%s\n' "$facts" | sed -n 's/^need=//p')"
  if [[ "$need" != true ]]; then
    fail "lib src scan: ${facts}"
  fi

  cat >"$repo/changelog.d/quote-path.md" <<'EOF'
category: fixed

- quoted
EOF
  git -C "$repo" add changelog.d
  git -C "$repo" commit -q -m fragment
  head="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$head")"
  fragments="$(printf '%s\n' "$facts" | sed -n 's/^fragments=//p')"
  breaking="$(printf '%s\n' "$facts" | sed -n 's/^breaking=//p')"
  if [[ "$fragments" != 1 || "$breaking" != 0 ]]; then
    fail "fixed fragment scan: ${facts}"
  fi

  cat >"$repo/changelog.d/break-it.md" <<'EOF'
category: breaking

- breaks
EOF
  git -C "$repo" add changelog.d
  git -C "$repo" commit -q -m break
  head="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$head")"
  breaking="$(printf '%s\n' "$facts" | sed -n 's/^breaking=//p')"
  if [[ "$breaking" != 1 ]]; then
    fail "breaking fragment scan: ${facts}"
  fi

  printf 'nope\n' >"$repo/changelog.d/Bad Name.md"
  git -C "$repo" add changelog.d
  git -C "$repo" commit -q -m bad
  head="$(git -C "$repo" rev-parse HEAD)"
  if (cd "$repo" && scan_diff "$base" "$head") >/dev/null 2>"$tmp/err"; then
    fail "invalid fragment accepted"
  fi

  if ! AUTHOR='dependabot[bot]' bash "$0" "$base" "$head" | grep -q 'Dependabot'; then
    fail "dependabot cli"
  fi

  rm -rf "$tmp"
  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
  echo "news-fragment self-test ok"
}

if [[ "${1:-}" == --self-test ]]; then
  self_test
  exit 0
fi

if [[ "${AUTHOR:-}" == "dependabot[bot]" ]]; then
  echo "Dependabot: fragment check skipped"
  exit 0
fi

old_ref="${1:?old ref}"
new_ref="${2:?new ref}"
ensure_commit "$old_ref"
ensure_commit "$new_ref"
facts="$(scan_diff "$old_ref" "$new_ref")"
need="$(printf '%s\n' "$facts" | sed -n 's/^need=//p')"
fragments="$(printf '%s\n' "$facts" | sed -n 's/^fragments=//p')"
breaking="$(printf '%s\n' "$facts" | sed -n 's/^breaking=//p')"
label="$(fetch_breaking_label)"
decide false "$need" "$label" "$fragments" "$breaking"
