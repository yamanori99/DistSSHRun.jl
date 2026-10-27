#!/usr/bin/env bash
# On a version cut, copy changelog.d fragments into NEWS.md and delete the
# ones that went into the new version section. Planned fragments stay.
# Feature pull requests do not edit NEWS.md.
#
# A fragment is changelog.d/<slug>.md. No YAML and no package field:
#   category: breaking|planned|added|fixed|changed|skip
#   <one-line reason, only for skip>
#   <blank line>
#   bullet text
#
# Usage:
#   ./.github/news-collect.sh
#   ./.github/news-collect.sh --check OLD_REF NEW_REF
#   ./.github/news-collect.sh --validate FILE
#   ./.github/news-collect.sh --self-test
#
# --check rebuilds the cut from the fragments in those two trees. A deleted
# file is read from the newest blob still in this clone. A planned fragment
# whose bullet landed in the new version section is read as category
# breaking, which is the one-line edit a cut makes before running this script.
set -euo pipefail
shopt -s nullglob

script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

slug_re='^[a-z0-9][a-z0-9.-]{0,60}\.md$'

die() {
  echo "news-collect: $*" >&2
  return 1
}

version_of() {
  local file="$1" version
  version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1)"
  if [[ -z "$version" ]]; then
    die "no version in ${file}"
    return 1
  fi
  case "$version" in
    *[!0-9A-Za-z.+-]*)
      die "unsupported version ${version}"
      return 1
      ;;
  esac
  printf '%s\n' "$version"
}

strip_trailing_blank_lines() {
  local file="$1" last tmp
  while [[ -s "$file" ]]; do
    last="$(tail -n 1 "$file")"
    if [[ -n "$last" ]]; then
      break
    fi
    tmp="$(mktemp)"
    head -n -1 "$file" >"$tmp"
    mv "$tmp" "$file"
  done
}

# Print the category. Write the bullet text to BODY_OUT.
validate_file() {
  local file="$1" body_out="$2" base line category reason rest_at i
  local -a lines=()
  base="$(basename "$file")"
  if [[ ! "$base" =~ $slug_re ]]; then
    die "${base} is not [a-z0-9][a-z0-9.-]{0,60}.md"
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    die "missing ${file}"
    return 1
  fi
  if grep -q $'\r' "$file"; then
    die "${base} must use LF line endings"
    return 1
  fi
  if grep -q '^## ' "$file"; then
    die "${base} must not contain a ## heading"
    return 1
  fi
  mapfile -t lines <"$file"
  if [[ ${#lines[@]} -lt 3 ]]; then
    die "${base} needs a category, a blank line, and bullet text"
    return 1
  fi
  category="${lines[0]}"
  reason=""
  rest_at=2
  case "$category" in
    "category: breaking" | "category: planned" | "category: added" | "category: fixed" | "category: changed")
      if [[ "${lines[1]}" != "" ]]; then
        die "${base} must have a blank line after the category"
        return 1
      fi
      ;;
    "category: skip")
      if [[ ${#lines[@]} -lt 4 ]]; then
        die "${base} skip needs a one-line reason, a blank line, and bullet text"
        return 1
      fi
      reason="${lines[1]}"
      if [[ -z "${reason//[[:space:]]/}" ]]; then
        die "${base} skip needs a one-line reason"
        return 1
      fi
      if [[ "${lines[2]}" != "" ]]; then
        die "${base} must have a blank line after the skip reason"
        return 1
      fi
      rest_at=3
      ;;
    *)
      die "${base} category must be breaking, planned, added, fixed, changed, or skip"
      return 1
      ;;
  esac
  : >"$body_out"
  for ((i = rest_at; i < ${#lines[@]}; i++)); do
    printf '%s\n' "${lines[$i]}" >>"$body_out"
  done
  strip_trailing_blank_lines "$body_out"
  if [[ ! -s "$body_out" ]]; then
    die "${base} needs bullet text"
    return 1
  fi
  if ! grep -q '^- ' "$body_out"; then
    die "${base} bullet text must include a '- ' line"
    return 1
  fi
  printf '%s\n' "${category#category: }"
}

load_dir() {
  local src="$1" dest="$2" path base category body
  mkdir -p "$dest/breaking" "$dest/planned" "$dest/added" "$dest/fixed" "$dest/changed" "$dest/skip"
  if [[ ! -d "$src" ]]; then
    die "missing ${src}"
    return 1
  fi
  for path in "$src"/*; do
    base="$(basename "$path")"
    if [[ ! -f "$path" ]]; then
      die "${base} is not a fragment file"
      return 1
    fi
    body="$(mktemp)"
    category="$(validate_file "$path" "$body")" || return 1
    mv "$body" "$dest/$category/$base"
  done
}

print_bodies() {
  local dir="$1" path
  local -a files=() sorted=()
  files=("$dir"/*)
  if [[ ${#files[@]} -eq 0 ]]; then
    return 0
  fi
  mapfile -t sorted < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)
  for path in "${sorted[@]}"; do
    cat "$path"
  done
}

count_files() {
  local dir="$1"
  local -a files=()
  files=("$dir"/*)
  printf '%s\n' "${#files[@]}"
}

render_unreleased() {
  local loaded="$1" out="$2"
  cat >"$out" <<'EOF'
## Unreleased

Notes since the last release are files in `changelog.d/`.
The version-cut PR copies them into this file.

### Planned breaking (next minor)
EOF
  if [[ "$(count_files "$loaded/planned")" -gt 0 ]]; then
    printf '\n' >>"$out"
    print_bodies "$loaded/planned" >>"$out"
  fi
}

render_release() {
  local loaded="$1" version="$2" out="$3" category count total=0
  for category in breaking changed added fixed; do
    count="$(count_files "$loaded/$category")"
    total=$((total + count))
  done
  if [[ "$total" -eq 0 ]]; then
    die "release section ## ${version} would be empty"
    return 1
  fi
  {
    printf '## %s\n' "$version"
    if [[ "$(count_files "$loaded/breaking")" -gt 0 ]]; then
      printf '\n### Breaking\n\n'
      print_bodies "$loaded/breaking"
    fi
    if [[ "$(count_files "$loaded/changed")" -gt 0 || "$(count_files "$loaded/added")" -gt 0 || "$(count_files "$loaded/fixed")" -gt 0 ]]; then
      printf '\n'
      for category in changed added fixed; do
        print_bodies "$loaded/$category"
      done
    fi
  } >"$out"
}

assemble_news() {
  local news="$1" version="$2" loaded="$3" out="$4"
  local line unreleased_line=0 next_line=0 n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    if [[ "$unreleased_line" -eq 0 && "$line" == "## Unreleased" ]]; then
      unreleased_line=$n
      continue
    fi
    if [[ "$unreleased_line" -ne 0 && "$next_line" -eq 0 && "$line" == "## "* ]]; then
      next_line=$n
      break
    fi
  done <"$news"
  if [[ "$unreleased_line" -eq 0 || "$next_line" -eq 0 ]]; then
    die "NEWS.md needs ## Unreleased and a later ## section"
    return 1
  fi
  if grep -F -x -q "## ${version}" "$news"; then
    die "NEWS.md already has ## ${version}"
    return 1
  fi
  local pre rest unr rel
  pre="$(mktemp)"
  rest="$(mktemp)"
  unr="$(mktemp)"
  rel="$(mktemp)"
  head -n $((unreleased_line - 1)) "$news" >"$pre"
  tail -n +"$next_line" "$news" >"$rest"
  render_unreleased "$loaded" "$unr" || return 1
  render_release "$loaded" "$version" "$rel" || return 1
  {
    cat "$pre"
    cat "$unr"
    printf '\n'
    cat "$rel"
    printf '\n'
    cat "$rest"
  } >"$out"
  rm -f "$pre" "$rest" "$unr" "$rel"
}

delete_consumed() {
  local src="$1" loaded="$2" category path base
  for category in breaking changed added fixed skip; do
    for path in "$loaded/$category"/*; do
      base="$(basename "$path")"
      rm -f "$src/$base"
    done
  done
}

apply_root() {
  local root="$1" version loaded out
  version="$(version_of "$root/Project.toml")"
  loaded="$(mktemp -d)"
  out="$(mktemp)"
  load_dir "$root/changelog.d" "$loaded" || return 1
  assemble_news "$root/NEWS.md" "$version" "$loaded" "$out" || return 1
  mv "$out" "$root/NEWS.md"
  delete_consumed "$root/changelog.d" "$loaded"
  rm -rf "$loaded"
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

list_fragment_paths() {
  local ref="$1" path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    printf '%s\n' "$path"
  done < <(git -c core.quotePath=false ls-tree -r --name-only "$ref" -- changelog.d || true)
}

write_best_blob() {
  local old="$1" new="$2" path="$3" dest="$4" commit=""
  if git cat-file -e "$new:$path" 2>/dev/null; then
    git cat-file -p "$new:$path" >"$dest"
    return 0
  fi
  if commit="$(git rev-list -n 1 "$new" -- "$path" 2>/dev/null || true)" && [[ -n "$commit" ]]; then
    if git cat-file -e "$commit:$path" 2>/dev/null; then
      git cat-file -p "$commit:$path" >"$dest"
      return 0
    fi
    if git cat-file -e "${commit}^:$path" 2>/dev/null; then
      git cat-file -p "${commit}^:$path" >"$dest"
      return 0
    fi
  fi
  git cat-file -p "$old:$path" >"$dest"
}

body_in_section() {
  local body="$1" section="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if ! grep -F -x -q -- "$line" "$section"; then
      return 1
    fi
  done <"$body"
  return 0
}

# A planned fragment deleted in this cut, whose bullet is in the new version
# section, was edited to category breaking in that same commit.
promote_released_planned() {
  local path="$1" version="$2" news="$3" present="$4"
  [[ "$present" == false ]] || return 0
  local body category section rewritten
  body="$(mktemp)"
  category="$(validate_file "$path" "$body")"
  if [[ "$category" != planned ]]; then
    rm -f "$body"
    return 0
  fi
  section="$(mktemp)"
  awk -v ver="$version" '
    $0 == "## " ver { on = 1; next }
    on && index($0, "## ") == 1 { exit }
    on { print }
  ' "$news" >"$section"
  if body_in_section "$body" "$section"; then
    rewritten="$(mktemp)"
    {
      printf 'category: breaking\n\n'
      cat "$body"
    } >"$rewritten"
    mv "$rewritten" "$path"
  fi
  rm -f "$body" "$section"
}

check_refs() {
  local old="$1" new="$2" work version path base present
  ensure_commit "$old"
  ensure_commit "$new"
  work="$(mktemp -d)"
  mkdir -p "$work/changelog.d"
  git cat-file -p "$old:NEWS.md" >"$work/NEWS.md"
  git cat-file -p "$new:Project.toml" >"$work/Project.toml"
  git cat-file -p "$new:NEWS.md" >"$work/head-news"
  version="$(version_of "$work/Project.toml")"
  local -a paths=()
  mapfile -t paths < <(
    {
      list_fragment_paths "$old"
      list_fragment_paths "$new"
      git -c core.quotePath=false log --diff-filter=D --name-only --pretty=format: "${old}..${new}" -- changelog.d 2>/dev/null || true
    } | LC_ALL=C sort -u
  )
  for path in "${paths[@]}"; do
    [[ -z "$path" ]] && continue
    case "$path" in
      changelog.d/*) ;;
      *) continue ;;
    esac
    base="$(basename "$path")"
    if git cat-file -e "$new:$path" 2>/dev/null; then
      present=true
    else
      present=false
    fi
    write_best_blob "$old" "$new" "$path" "$work/changelog.d/$base"
    promote_released_planned "$work/changelog.d/$base" "$version" "$work/head-news" "$present"
  done
  apply_root "$work"
  if ! cmp -s "$work/NEWS.md" "$work/head-news"; then
    diff -u "$work/head-news" "$work/NEWS.md" >&2 || true
    rm -rf "$work"
    die "NEWS.md does not match collected fragments"
  fi
  local got head_list name
  got="$(mktemp)"
  head_list="$(mktemp)"
  for path in "$work/changelog.d"/*; do
    printf '%s\n' "$(basename "$path")"
  done | LC_ALL=C sort >"$got"
  list_fragment_paths "$new" | sed 's|^changelog.d/||' | LC_ALL=C sort >"$head_list"
  if ! cmp -s "$got" "$head_list"; then
    diff -u "$head_list" "$got" >&2 || true
    rm -f "$got" "$head_list"
    rm -rf "$work"
    die "consumed fragments are still in changelog.d, or a planned fragment is missing"
  fi
  local mismatch=false
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! cmp -s "$work/changelog.d/$name" <(git cat-file -p "$new:changelog.d/$name"); then
      echo "news-collect: planned fragment ${name} does not match" >&2
      mismatch=true
    fi
  done <"$head_list"
  rm -f "$got" "$head_list"
  if [[ "$mismatch" == true ]]; then
    rm -rf "$work"
    return 1
  fi
  rm -rf "$work"
  echo "news-collect: NEWS.md matches the fragments"
}

repo_root() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$top" ]]; then
    printf '%s\n' "$top"
    return 0
  fi
  cd "$(dirname "$0")/.." && pwd
}

self_test() {
  local tmp failed=0
  tmp="$(mktemp -d)"
  fail() {
    echo "FAIL $*" >&2
    failed=1
  }
  write_project() {
    printf 'name = "Example"\nversion = "%s"\n' "$1" >"$2/Project.toml"
  }
  write_news() {
    cat >"$1/NEWS.md" <<'EOF'
# News

Intro.

## Unreleased

- old note

## 0.1.0

- released
EOF
  }
  expect_fail() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>"$tmp/err"; then
      fail "${name} want failure"
    fi
  }

  local root="$tmp/apply"
  mkdir -p "$root/changelog.d"
  write_project 0.2.0 "$root"
  write_news "$root"
  cat >"$root/changelog.d/b-change.md" <<'EOF'
category: changed

- change b
EOF
  cat >"$root/changelog.d/a-change.md" <<'EOF'
category: changed

- change a
EOF
  cat >"$root/changelog.d/add.md" <<'EOF'
category: added

- add
EOF
  cat >"$root/changelog.d/fix.md" <<'EOF'
category: fixed

- fix
EOF
  cat >"$root/changelog.d/break.md" <<'EOF'
category: breaking

- break
EOF
  cat >"$root/changelog.d/plan-b.md" <<'EOF'
category: planned

- plan b
EOF
  cat >"$root/changelog.d/plan-a.md" <<'EOF'
category: planned

- plan a
EOF
  cat >"$root/changelog.d/quiet.md" <<'EOF'
category: skip
no user-facing change

- internal
EOF
  apply_root "$root"
  cat >"$tmp/expect-news" <<'EOF'
# News

Intro.

## Unreleased

Notes since the last release are files in `changelog.d/`.
The version-cut PR copies them into this file.

### Planned breaking (next minor)

- plan a
- plan b

## 0.2.0

### Breaking

- break

- change a
- change b
- add
- fix

## 0.1.0

- released
EOF
  if ! cmp -s "$root/NEWS.md" "$tmp/expect-news"; then
    diff -u "$tmp/expect-news" "$root/NEWS.md" >&2 || true
    fail "apply news"
  fi
  local left
  left="$(find "$root/changelog.d" -type f -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')"
  if [[ "$left" != "plan-a.md plan-b.md " ]]; then
    fail "apply kept files: ${left}"
  fi

  local empty="$tmp/empty"
  mkdir -p "$empty/changelog.d"
  write_project 0.1.1 "$empty"
  write_news "$empty"
  cat >"$empty/changelog.d/later.md" <<'EOF'
category: planned

- later
EOF
  cp "$empty/NEWS.md" "$tmp/empty-before"
  expect_fail "empty release" apply_root "$empty"
  if ! cmp -s "$empty/NEWS.md" "$tmp/empty-before"; then
    fail "empty release modified NEWS.md"
  fi
  if [[ ! -f "$empty/changelog.d/later.md" ]]; then
    fail "empty release deleted a planned fragment"
  fi

  local bad="$tmp/bad"
  mkdir -p "$bad/changelog.d"
  printf 'category: fixed\npackage: DistSSHRun\n\n- x\n' >"$bad/changelog.d/pkg.md"
  if validate_file "$bad/changelog.d/pkg.md" "$tmp/body" >/dev/null 2>"$tmp/err"; then
    fail "package field accepted"
  fi
  printf 'category: fixed\n\n## 1.0.0\n\n- x\n' >"$bad/changelog.d/heading.md"
  if validate_file "$bad/changelog.d/heading.md" "$tmp/body" >/dev/null 2>"$tmp/err"; then
    fail "heading accepted"
  fi
  printf 'category: skip\n\n- x\n' >"$bad/changelog.d/skip.md"
  if validate_file "$bad/changelog.d/skip.md" "$tmp/body" >/dev/null 2>"$tmp/err"; then
    fail "skip without reason accepted"
  fi
  printf 'category: fixed\n\n- x\n' >"$bad/changelog.d/Bad.md"
  if validate_file "$bad/changelog.d/Bad.md" "$tmp/body" >/dev/null 2>"$tmp/err"; then
    fail "bad slug accepted"
  fi

  local repo="$tmp/repo" base head
  mkdir -p "$repo/changelog.d"
  git -C "$repo" init -q
  git -C "$repo" config user.email "news-collect@example.com"
  git -C "$repo" config user.name "news-collect"
  git -C "$repo" config commit.gpgsign false
  write_project 0.1.0 "$repo"
  write_news "$repo"
  cat >"$repo/changelog.d/fix.md" <<'EOF'
category: fixed

- fix
EOF
  cat >"$repo/changelog.d/promote.md" <<'EOF'
category: planned

- promoted
EOF
  git -C "$repo" add Project.toml NEWS.md changelog.d
  git -C "$repo" commit -q -m base
  base="$(git -C "$repo" rev-parse HEAD)"
  printf 'name = "Example"\nversion = "0.2.0"\n' >"$repo/Project.toml"
  cat >"$repo/changelog.d/promote.md" <<'EOF'
category: breaking

- promoted
EOF
  apply_root "$repo"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m cut
  head="$(git -C "$repo" rev-parse HEAD)"
  if ! (cd "$repo" && bash "$script_path" --check "$base" "$head") >"$tmp/check-out" 2>"$tmp/check-err"; then
    cat "$tmp/check-err" >&2
    fail "check after apply"
  fi
  printf '\n- edited\n' >>"$repo/NEWS.md"
  git -C "$repo" add NEWS.md
  git -C "$repo" commit -q -m edit
  local edited
  edited="$(git -C "$repo" rev-parse HEAD)"
  if (cd "$repo" && bash "$script_path" --check "$base" "$edited") >/dev/null 2>"$tmp/check-err"; then
    fail "check accepted a hand-edited NEWS.md"
  fi

  rm -rf "$tmp"
  if [[ "$failed" -ne 0 ]]; then
    exit 1
  fi
  echo "news-collect self-test ok"
}

if [[ "${1:-}" == --self-test ]]; then
  self_test
  exit 0
fi

if [[ "${1:-}" == --validate ]]; then
  file="${2:?file}"
  body="$(mktemp)"
  category="$(validate_file "$file" "$body")"
  rm -f "$body"
  printf '%s\n' "$category"
  exit 0
fi

if [[ "${1:-}" == --check ]]; then
  check_refs "${2:?old ref}" "${3:?new ref}"
  exit 0
fi

if [[ $# -ne 0 ]]; then
  die "unknown argument: ${1}"
  exit 1
fi

apply_root "$(repo_root)"
echo "news-collect: wrote NEWS.md and removed consumed fragments"
