#!/usr/bin/env bash
# Pull requests that do not cut a version:
# - a change under src/**, lib/**/src/**, or ext/** needs one valid fragment
#   (an edit of an existing breaking fragment does not count)
# - Dependabot is exempt
# - a fragment that becomes breaking requires the breaking label
# - the breaking label requires a new or still-breaking edited fragment
# - an edit that stays breaking does not require the label
# The diff is from the merge base of the two refs to the new ref. When
# git merge-base cannot see that commit, the Compare API supplies it.
# A failure there stops the check. The two-dot diff of the tips is not used.
# Planned fragments do not require the breaking label. A version cut does
# not run this script.
#
# Usage:
#   ./.github/news-fragment.sh OLD_REF NEW_REF
#   ./.github/news-fragment.sh --self-test
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script_path="${here}/$(basename "$0")"

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

# Local history when the two commits are connected. Otherwise the Compare
# API's merge_base_commit.sha, fetched at depth 1. Never diff the tips.
resolve_diff_base() {
  local old="$1" new="$2" mb token repo
  if mb="$(git merge-base "$old" "$new" 2>/dev/null)" && [[ -n "$mb" ]]; then
    printf '%s\n' "$mb"
    return 0
  fi
  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  repo="${GITHUB_REPOSITORY:-}"
  if [[ -z "$token" || -z "$repo" ]]; then
    die "could not resolve merge base"
    return 1
  fi
  if ! mb="$(gh api --jq '.merge_base_commit.sha' "repos/${repo}/compare/${old}...${new}")"; then
    die "could not resolve merge base"
    return 1
  fi
  if [[ ! "$mb" =~ ^[0-9a-fA-F]{40}$ ]]; then
    die "could not resolve merge base"
    return 1
  fi
  if ! ensure_commit "$mb"; then
    die "could not resolve merge base"
    return 1
  fi
  printf '%s\n' "$mb"
}

# breaking, other, or missing. The blob is stored in a variable. A pipe
# would trip pipefail when the path is absent, and --validate would reject
# a breaking first line that is missing its blank line.
base_line_kind() {
  local old="$1" path="$2" blob first
  if ! blob="$(git cat-file -p "$old:$path" 2>/dev/null)"; then
    printf 'missing\n'
    return 0
  fi
  first="${blob%%$'\n'*}"
  if [[ "$first" == "category: breaking" ]]; then
    printf 'breaking\n'
  else
    printf 'other\n'
  fi
}

head_category() {
  local new="$1" path="$2" dir dest category
  dir="$(mktemp -d)"
  dest="$dir/$(basename "$path")"
  if ! git cat-file -p "$new:$path" >"$dest" 2>/dev/null; then
    rm -rf "$dir"
    return 1
  fi
  if ! category="$("$here/news-collect.sh" --validate "$dest")"; then
    rm -rf "$dir"
    return 1
  fi
  rm -rf "$dir"
  printf '%s\n' "$category"
}

count_head_fragment() {
  local base_cat="$1" head_cat="$2"
  if [[ "$base_cat" == missing ]]; then
    anomaly=$((anomaly + 1))
    if [[ "$head_cat" == breaking ]]; then
      introduced=$((introduced + 1))
    fi
    fragments=$((fragments + 1))
    return 0
  fi
  if [[ "$head_cat" == breaking && "$base_cat" == breaking ]]; then
    edited=$((edited + 1))
    return 0
  fi
  if [[ "$head_cat" == breaking ]]; then
    introduced=$((introduced + 1))
    fragments=$((fragments + 1))
    return 0
  fi
  if [[ "$base_cat" == breaking ]]; then
    removed=$((removed + 1))
    fragments=$((fragments + 1))
    return 0
  fi
  fragments=$((fragments + 1))
}

# Print need, fragment, introduced, edited, removed, and anomaly counts.
# fragments excludes an edit that stays breaking. anomaly is a base blob
# that git named but cat-file could not read.
scan_diff() {
  local old="$1" new="$2"
  local need=false fragments=0 introduced=0 edited=0 removed=0 anomaly=0
  local status p1 p2 path head_cat base_cat
  while IFS=$'\t' read -r status p1 p2; do
    [[ -z "${status:-}" ]] && continue
    case "$status" in
      R* | C*)
        die "unexpected diff status ${status} ${p1:-} ${p2:-}"
        return 1
        ;;
      D)
        path_needs_fragment "$p1" && need=true
        path="$p1"
        if is_fragment_path "$path"; then
          base_cat="$(base_line_kind "$old" "$path")"
          if [[ "$base_cat" == breaking ]]; then
            removed=$((removed + 1))
          elif [[ "$base_cat" == missing ]]; then
            anomaly=$((anomaly + 1))
          fi
        elif [[ "$path" == changelog.d/* ]]; then
          die "${path} is not a fragment file"
          return 1
        fi
        continue
        ;;
      A | M | T)
        path_needs_fragment "$p1" && need=true
        path="$p1"
        ;;
      *)
        die "unexpected diff status ${status}"
        return 1
        ;;
    esac
    if is_fragment_path "$path"; then
      if ! head_cat="$(head_category "$new" "$path")"; then
        return 1
      fi
      if [[ "$status" == A ]]; then
        if [[ "$head_cat" == breaking ]]; then
          introduced=$((introduced + 1))
        fi
        fragments=$((fragments + 1))
      else
        base_cat="$(base_line_kind "$old" "$path")"
        count_head_fragment "$base_cat" "$head_cat"
      fi
    elif [[ "$path" == changelog.d/* ]]; then
      die "${path} is not a fragment file"
      return 1
    fi
  done < <(git -c core.quotePath=false diff --name-status --no-renames "$old" "$new")
  printf 'need=%s\nfragments=%s\nintroduced=%s\nedited=%s\nremoved=%s\nanomaly=%s\n' \
    "$need" "$fragments" "$introduced" "$edited" "$removed" "$anomaly"
}

decide() {
  local dependabot="$1" need="$2" label="$3" fragments="$4"
  local introduced="$5" edited="$6" removed="$7" anomaly="${8:-0}"
  if [[ "$dependabot" == true ]]; then
    echo "Dependabot: fragment check skipped"
    return 0
  fi
  if [[ "$edited" -gt 0 && "$label" != true ]]; then
    echo "::notice::edited an existing breaking fragment; breaking label not required for a factual correction"
  fi
  if [[ "$removed" -gt 0 ]]; then
    echo "::warning::a breaking fragment was removed or demoted; confirm that was intended"
  fi
  if [[ "$anomaly" -gt 0 ]]; then
    echo "::warning::could not read a changelog fragment on the merge base"
  fi
  if [[ "$need" == true && "$fragments" -lt 1 ]]; then
    die "changes under src/, lib/**/src/, or ext/ need a changelog.d fragment"
    return 1
  fi
  if [[ "$introduced" -gt 0 && "$label" != true ]]; then
    die "category: breaking requires the breaking label"
    return 1
  fi
  if [[ "$label" == true && $((introduced + edited)) -lt 1 ]]; then
    die "breaking label requires a fragment with category: breaking"
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
  local tmp failed=0 repo base tip facts need fragments introduced edited removed
  local main_rev fork_rev topic_rev diff_base out st got ns
  tmp="$(mktemp -d)"
  fail() {
    echo "FAIL $*" >&2
    failed=1
  }
  write_frag() {
    local path="$1" catg="$2" body="$3"
    mkdir -p "$(dirname "$path")"
    printf 'category: %s\n\n- %s\n' "$catg" "$body" >"$path"
  }
  field() {
    printf '%s\n' "$2" | sed -n "s/^$1=//p"
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

  if ! decide true true false 0 0 0 0 0 | grep -q 'Dependabot'; then
    fail "dependabot"
  fi
  if decide false true false 0 0 0 0 0 >/dev/null 2>"$tmp/err"; then
    fail "src without fragment"
  fi
  if ! decide false true false 1 0 0 0 0 >/dev/null; then
    fail "src with fragment"
  fi
  if decide false false false 1 1 0 0 0 >/dev/null 2>"$tmp/err"; then
    fail "breaking fragment without label"
  fi
  if decide false false true 0 0 0 0 0 >/dev/null 2>"$tmp/err"; then
    fail "label without fragment"
  fi
  if ! decide false false true 1 1 0 0 0 >/dev/null; then
    fail "breaking pair"
  fi
  if ! decide false false false 1 0 0 0 0 >/dev/null; then
    fail "planned or fixed without label"
  fi
  out="$(decide false false false 0 0 1 0 0 2>"$tmp/err")"
  if ! printf '%s\n' "$out" | grep -q '::notice::'; then
    fail "edited notice missing"
  fi
  if ! printf '%s\n' "$out" | grep -q 'news-fragment: ok'; then
    fail "edited without label should pass"
  fi
  if grep -q '::notice::' "$tmp/err"; then
    fail "notice on stderr"
  fi
  out="$(decide false false true 0 0 1 0 0 2>"$tmp/err")"
  if printf '%s\n' "$out" | grep -q '::notice::'; then
    fail "notice emitted with label"
  fi
  if ! printf '%s\n' "$out" | grep -q 'news-fragment: ok'; then
    fail "edited with label should pass"
  fi
  if decide false true false 0 0 1 0 0 >"$tmp/out" 2>"$tmp/err"; then
    fail "src plus edited only should fail"
  fi
  if ! grep -q '::notice::' "$tmp/out"; then
    fail "notice before need failure"
  fi
  if ! grep -q 'need a changelog.d fragment' "$tmp/err"; then
    fail "need message: $(cat "$tmp/err")"
  fi
  if ! decide false true false 1 0 1 0 0 >/dev/null; then
    fail "src plus edited plus another fragment"
  fi
  out="$(decide false false false 1 0 0 1 0 2>"$tmp/err")"
  if ! printf '%s\n' "$out" | grep -q '::warning::'; then
    fail "demotion warning missing"
  fi
  if grep -q '::warning::' "$tmp/err"; then
    fail "warning on stderr"
  fi
  if ! printf '%s\n' "$out" | grep -q 'news-fragment: ok'; then
    fail "demotion without label should pass"
  fi
  if decide false false true 1 0 0 1 0 >"$tmp/out" 2>"$tmp/err"; then
    fail "label with only a demotion should fail"
  fi
  if ! grep -q 'breaking label requires a fragment' "$tmp/err"; then
    fail "label without breaking: $(cat "$tmp/err")"
  fi
  out="$(decide false false false 0 0 0 0 1 2>"$tmp/err")"
  if ! printf '%s\n' "$out" | grep -q 'could not read a changelog fragment'; then
    fail "anomaly warning missing"
  fi

  printf 'docs\n' >"$repo/docs/a.md"
  git -C "$repo" add docs
  git -C "$repo" commit -q -m docs
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  need="$(field need "$facts")"
  fragments="$(field fragments "$facts")"
  if [[ "$need" != false || "$fragments" != 0 ]]; then
    fail "docs-only scan: ${facts}"
  fi

  printf 'lib\n' >"$repo/lib/DistSSHBase/src/a.jl"
  git -C "$repo" add lib
  git -C "$repo" commit -q -m lib
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  need="$(field need "$facts")"
  if [[ "$need" != true ]]; then
    fail "lib src scan: ${facts}"
  fi

  cat >"$repo/changelog.d/quote-path.md" <<'EOF'
category: fixed

- quoted
EOF
  git -C "$repo" add changelog.d
  git -C "$repo" commit -q -m fragment
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  fragments="$(field fragments "$facts")"
  introduced="$(field introduced "$facts")"
  if [[ "$fragments" != 1 || "$introduced" != 0 ]]; then
    fail "fixed fragment scan: ${facts}"
  fi

  cat >"$repo/changelog.d/break-it.md" <<'EOF'
category: breaking

- breaks
EOF
  git -C "$repo" add changelog.d
  git -C "$repo" commit -q -m break
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  introduced="$(field introduced "$facts")"
  if [[ "$introduced" != 1 ]]; then
    fail "breaking fragment scan: ${facts}"
  fi

  printf 'nope\n' >"$repo/changelog.d/Bad Name.md"
  git -C "$repo" add changelog.d
  git -C "$repo" commit -q -m bad
  tip="$(git -C "$repo" rev-parse HEAD)"
  if (cd "$repo" && scan_diff "$base" "$tip") >/dev/null 2>"$tmp/err"; then
    fail "invalid fragment accepted"
  fi

  if ! AUTHOR='dependabot[bot]' bash "$script_path" "$base" "$tip" | grep -q 'Dependabot'; then
    fail "dependabot cli"
  fi

  # Classification on a repo whose base already holds the fragments.
  repo="$tmp/class"
  mkdir -p "$repo/src" "$repo/changelog.d"
  git -C "$repo" init -q
  git -C "$repo" config user.email "news-fragment@example.com"
  git -C "$repo" config user.name "news-fragment"
  git -C "$repo" config commit.gpgsign false
  printf 'base\n' >"$repo/src/a.jl"
  write_frag "$repo/changelog.d/stay.md" breaking "original breaking text that is long enough"
  write_frag "$repo/changelog.d/prom-p.md" planned "planned note"
  write_frag "$repo/changelog.d/prom-f.md" fixed "fixed note"
  write_frag "$repo/changelog.d/prom-a.md" added "added note"
  write_frag "$repo/changelog.d/demo.md" breaking "demote me"
  write_frag "$repo/changelog.d/gone.md" breaking "delete me"
  write_frag "$repo/changelog.d/plain.md" changed "plain note"
  printf 'category: breaking\nnot a blank line\n- bullet\n' >"$repo/changelog.d/bad.md"
  git -C "$repo" add src changelog.d
  git -C "$repo" commit -q -m fragments
  base="$(git -C "$repo" rev-parse HEAD)"

  git -C "$repo" checkout -q -B work "$base"
  write_frag "$repo/changelog.d/stay.md" breaking "original breaking text that is long enough, corrected"
  git -C "$repo" add changelog.d/stay.md
  git -C "$repo" commit -q -m 'edit body'
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  if [[ "$(field edited "$facts")" != 1 || "$(field introduced "$facts")" != 0 || "$(field fragments "$facts")" != 0 ]]; then
    fail "body-only edit: ${facts}"
  fi
  if ! (cd "$repo" && decide false false false 0 0 1 0 0) | grep -q 'news-fragment: ok'; then
    fail "body-only decide"
  fi

  git -C "$repo" checkout -q -B work "$base"
  write_frag "$repo/changelog.d/stay.md" breaking "original breaking text that is long enough, corrected"
  printf 'code\n' >>"$repo/src/a.jl"
  git -C "$repo" add changelog.d/stay.md src/a.jl
  git -C "$repo" commit -q -m 'src and edit'
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  if [[ "$(field need "$facts")" != true || "$(field fragments "$facts")" != 0 || "$(field edited "$facts")" != 1 ]]; then
    fail "src plus edited scan: ${facts}"
  fi

  git -C "$repo" checkout -q -B work "$base"
  write_frag "$repo/changelog.d/stay.md" breaking "original breaking text that is long enough, corrected"
  write_frag "$repo/changelog.d/note.md" changed "the src change"
  printf 'code\n' >>"$repo/src/a.jl"
  git -C "$repo" add changelog.d src/a.jl
  git -C "$repo" commit -q -m 'src edit changed'
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  if [[ "$(field need "$facts")" != true || "$(field fragments "$facts")" != 1 || "$(field edited "$facts")" != 1 || "$(field introduced "$facts")" != 0 ]]; then
    fail "edited plus changed: ${facts}"
  fi

  git -C "$repo" checkout -q -B work "$base"
  write_frag "$repo/changelog.d/stay.md" breaking "original breaking text that is long enough, corrected"
  printf 'category: skip\ninternal\n\n- hidden\n' >"$repo/changelog.d/note.md"
  printf 'code\n' >>"$repo/src/a.jl"
  git -C "$repo" add changelog.d src/a.jl
  git -C "$repo" commit -q -m 'src edit skip'
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  if [[ "$(field fragments "$facts")" != 1 || "$(field edited "$facts")" != 1 || "$(field introduced "$facts")" != 0 ]]; then
    fail "edited plus skip: ${facts}"
  fi

  local slug from
  for spec in "prom-p:planned" "prom-f:fixed" "prom-a:added"; do
    slug="${spec%%:*}"
    from="${spec##*:}"
    git -C "$repo" checkout -q -B work "$base"
    write_frag "$repo/changelog.d/${slug}.md" breaking "now breaking from ${from} with enough words"
    git -C "$repo" add "changelog.d/${slug}.md"
    git -C "$repo" commit -q -m "promote ${from}"
    tip="$(git -C "$repo" rev-parse HEAD)"
    facts="$(cd "$repo" && scan_diff "$base" "$tip")"
    if [[ "$(field introduced "$facts")" != 1 || "$(field edited "$facts")" != 0 ]]; then
      fail "promotion ${from}: ${facts}"
    fi
  done

  git -C "$repo" checkout -q -B work "$base"
  write_frag "$repo/changelog.d/fresh.md" breaking "brand new break"
  git -C "$repo" add changelog.d/fresh.md
  git -C "$repo" commit -q -m fresh
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  if [[ "$(field introduced "$facts")" != 1 || "$(field fragments "$facts")" != 1 ]]; then
    fail "new breaking file: ${facts}"
  fi

  git -C "$repo" checkout -q -B work "$base"
  write_frag "$repo/changelog.d/demo.md" fixed "no longer breaking"
  git -C "$repo" add changelog.d/demo.md
  git -C "$repo" commit -q -m demote
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  if [[ "$(field removed "$facts")" != 1 || "$(field introduced "$facts")" != 0 || "$(field fragments "$facts")" != 1 ]]; then
    fail "demotion scan: ${facts}"
  fi

  git -C "$repo" checkout -q -B work "$base"
  git -C "$repo" rm -q changelog.d/gone.md
  git -C "$repo" commit -q -m delete
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  if [[ "$(field removed "$facts")" != 1 || "$(field fragments "$facts")" != 0 || "$(field introduced "$facts")" != 0 ]]; then
    fail "delete scan: ${facts}"
  fi

  git -C "$repo" checkout -q -B work "$base"
  git -C "$repo" mv changelog.d/stay.md changelog.d/stay-renamed.md
  git -C "$repo" commit -q -m rename
  tip="$(git -C "$repo" rev-parse HEAD)"
  ns="$(git -C "$repo" -c core.quotePath=false diff --name-status --find-renames "$base" "$tip")"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  if [[ "$ns" != $'R100\tchangelog.d/stay.md\tchangelog.d/stay-renamed.md' ]]; then
    fail "rename was not similar: ${ns}"
  fi
  if [[ "$(field introduced "$facts")" != 1 || "$(field removed "$facts")" != 1 || "$(field edited "$facts")" != 0 ]]; then
    fail "rename scan: ${facts}"
  fi

  git -C "$repo" checkout -q -B work "$base"
  git -C "$repo" rm -q changelog.d/stay.md
  write_frag "$repo/changelog.d/stay-again.md" breaking "original breaking text that is long enough"
  git -C "$repo" add changelog.d
  git -C "$repo" commit -q -m readd
  tip="$(git -C "$repo" rev-parse HEAD)"
  ns="$(git -C "$repo" -c core.quotePath=false diff --name-status --find-renames "$base" "$tip")"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  if [[ "$ns" != $'R100\tchangelog.d/stay.md\tchangelog.d/stay-again.md' ]]; then
    fail "similar readd was not a rename: ${ns}"
  fi
  if [[ "$(field introduced "$facts")" != 1 || "$(field removed "$facts")" != 1 ]]; then
    fail "similar readd scan: ${facts}"
  fi

  git -C "$repo" checkout -q -B work "$base"
  git -C "$repo" rm -q changelog.d/stay.md
  write_frag "$repo/changelog.d/totally-new.md" breaking "unrelated sentence about something else entirely"
  git -C "$repo" add changelog.d
  git -C "$repo" commit -q -m dissimilar
  tip="$(git -C "$repo" rev-parse HEAD)"
  ns="$(git -C "$repo" -c core.quotePath=false diff --name-status --find-renames "$base" "$tip")"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  if ! printf '%s\n' "$ns" | grep -q $'^D\tchangelog.d/stay.md$' \
    || ! printf '%s\n' "$ns" | grep -q $'^A\tchangelog.d/totally-new.md$'; then
    fail "dissimilar statuses: ${ns}"
  fi
  if [[ "$(field introduced "$facts")" != 1 || "$(field removed "$facts")" != 1 ]]; then
    fail "dissimilar scan: ${facts}"
  fi

  git -C "$repo" checkout -q -B work "$base"
  printf 'category: breaking\n\n- bullet now valid\n' >"$repo/changelog.d/bad.md"
  git -C "$repo" add changelog.d/bad.md
  git -C "$repo" commit -q -m 'repair bad'
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$base" "$tip")"
  if [[ "$(field edited "$facts")" != 1 || "$(field introduced "$facts")" != 0 ]]; then
    fail "malformed breaking base: ${facts}"
  fi
  git -C "$repo" show "${base}:changelog.d/bad.md" >"$tmp/bad-base.md"
  if bash "$here/news-collect.sh" --validate "$tmp/bad-base.md" >/dev/null 2>"$tmp/err"; then
    fail "base blob should fail validate"
  fi
  got="$(cd "$repo" && base_line_kind "$base" changelog.d/bad.md)"
  if [[ "$got" != breaking ]]; then
    fail "exact first line: ${got}"
  fi

  git -C "$repo" checkout -q -B work "$base"
  printf 'category: oops\n\n- x\n' >"$repo/changelog.d/weird.md"
  git -C "$repo" add changelog.d/weird.md
  git -C "$repo" commit -q -m weird
  local weird_base
  weird_base="$(git -C "$repo" rev-parse HEAD)"
  printf 'category: breaking\n\n- x\n' >"$repo/changelog.d/weird.md"
  git -C "$repo" add changelog.d/weird.md
  git -C "$repo" commit -q -m 'weird to breaking'
  tip="$(git -C "$repo" rev-parse HEAD)"
  facts="$(cd "$repo" && scan_diff "$weird_base" "$tip")"
  if [[ "$(field introduced "$facts")" != 1 || "$(field edited "$facts")" != 0 ]]; then
    fail "non-breaking first line: ${facts}"
  fi

  got="$(cd "$repo" && base_line_kind "$base" changelog.d/missing.md)"
  if [[ "$got" != missing ]]; then
    fail "missing base kind: ${got}"
  fi
  set +e
  (cd "$repo" && git cat-file -p "$base:changelog.d/missing.md" | sed -n '1p') >/dev/null 2>"$tmp/err"
  st=$?
  set -e
  if [[ "$st" -eq 0 ]]; then
    fail "pipe over a missing blob did not fail"
  fi

  # A fold on main deletes a breaking fragment. The old branch still has it.
  # merge-base ignores it. The tip-to-tip diff counts it as introduced.
  repo="$tmp/fold"
  mkdir -p "$repo/src" "$repo/changelog.d"
  git -C "$repo" init -q
  git -C "$repo" config user.email "news-fragment@example.com"
  git -C "$repo" config user.name "news-fragment"
  git -C "$repo" config commit.gpgsign false
  printf 'base\n' >"$repo/src/a.jl"
  write_frag "$repo/changelog.d/old-break.md" breaking "ships in the cut and has a distinctive sentence"
  {
    echo "# News"
    echo
    i=0
    while [[ "$i" -lt 40 ]]; do
      echo "- older note ${i} stays in the file"
      i=$((i + 1))
    done
  } >"$repo/NEWS.md"
  git -C "$repo" add src changelog.d NEWS.md
  git -C "$repo" commit -q -m fork
  fork_rev="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" rm -q changelog.d/old-break.md
  {
    echo "# News"
    echo
    echo "## 0.2.0"
    echo
    echo "- ships in the cut and has a distinctive sentence"
    i=0
    while [[ "$i" -lt 40 ]]; do
      echo "- older note ${i} stays in the file"
      i=$((i + 1))
    done
  } >"$repo/NEWS.md"
  git -C "$repo" add NEWS.md
  git -C "$repo" commit -q -m fold
  main_rev="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -q -B topic "$fork_rev"
  printf 'doc\n' >"$repo/docs.txt"
  git -C "$repo" add docs.txt
  git -C "$repo" commit -q -m docs
  topic_rev="$(git -C "$repo" rev-parse HEAD)"
  diff_base="$(
    cd "$repo"
    GH_TOKEN=bogus GITHUB_TOKEN=bogus GITHUB_REPOSITORY=nobody/nope \
      resolve_diff_base "$main_rev" "$topic_rev"
  )"
  if [[ "$diff_base" != "$fork_rev" ]]; then
    fail "fold merge-base ${diff_base}"
  fi
  facts="$(cd "$repo" && scan_diff "$diff_base" "$topic_rev")"
  if [[ "$(field introduced "$facts")" != 0 || "$(field fragments "$facts")" != 0 || "$(field need "$facts")" != false ]]; then
    fail "fold merge-base scan: ${facts}"
  fi
  facts="$(cd "$repo" && scan_diff "$main_rev" "$topic_rev")"
  if [[ "$(field introduced "$facts")" != 1 ]]; then
    fail "fold two-dot scan: ${facts}"
  fi

  # Depth-1 fetches of the two tips are not connected. Resolving must fail
  # closed instead of diffing the tips. No token, so the API is not called.
  git init -q "$tmp/shallow"
  git -C "$tmp/shallow" remote add origin "file://${repo}"
  git -C "$tmp/shallow" fetch --quiet --depth=1 origin "$main_rev"
  git -C "$tmp/shallow" fetch --quiet --depth=1 origin "$topic_rev"
  if git -C "$tmp/shallow" merge-base "$main_rev" "$topic_rev" >/dev/null 2>"$tmp/err"; then
    fail "depth-1 unexpectedly had a merge base"
  fi
  if diff_base="$(
    cd "$tmp/shallow"
    unset GH_TOKEN GITHUB_TOKEN GITHUB_REPOSITORY PR
    resolve_diff_base "$main_rev" "$topic_rev" 2>"$tmp/err"
  )"; then
    fail "depth-1 resolved ${diff_base}"
  fi
  if ! grep -q 'could not resolve merge base' "$tmp/err"; then
    fail "depth-1 error: $(cat "$tmp/err")"
  fi

  # fetch-depth 2 on a merge commit checks out the two tips, not the fork.
  git -C "$repo" checkout -q -B mainline "$main_rev"
  git -C "$repo" checkout -q -B topic "$fork_rev"
  printf 'topic-side\n' >"$repo/src/topic-only.jl"
  git -C "$repo" add src/topic-only.jl
  git -C "$repo" commit -q -m 'topic moves'
  topic_rev="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -q mainline
  printf 'main-side\n' >"$repo/src/main-only.jl"
  git -C "$repo" add src/main-only.jl
  git -C "$repo" commit -q -m 'main moves'
  main_rev="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" merge -q --no-ff -m 'merge topic' "$topic_rev"
  git clone --quiet --depth=2 --branch mainline "file://${repo}" "$tmp/depth2"
  if ! git -C "$tmp/depth2" rev-parse 'HEAD^2' >/dev/null 2>&1; then
    fail "depth-2 clone is not a merge"
  fi
  if git -C "$tmp/depth2" merge-base 'HEAD^1' 'HEAD^2' >/dev/null 2>"$tmp/err"; then
    fail "depth-2 parents had a merge base"
  fi
  ns="$(git -C "$tmp/depth2" diff --name-status 'HEAD^1' 'HEAD^2')"
  if ! printf '%s\n' "$ns" | grep -q 'src/main-only.jl' \
    || ! printf '%s\n' "$ns" | grep -q 'src/topic-only.jl'; then
    fail "depth-2 parent diff: ${ns}"
  fi
  local parent1 parent2
  parent1="$(git -C "$tmp/depth2" rev-parse 'HEAD^1')"
  parent2="$(git -C "$tmp/depth2" rev-parse 'HEAD^2')"
  if diff_base="$(
    cd "$tmp/depth2"
    unset GH_TOKEN GITHUB_TOKEN GITHUB_REPOSITORY PR
    resolve_diff_base "$parent1" "$parent2" 2>"$tmp/err"
  )"; then
    fail "depth-2 resolved ${diff_base}"
  fi
  if ! grep -q 'could not resolve merge base' "$tmp/err"; then
    fail "depth-2 error: $(cat "$tmp/err")"
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
diff_base="$(resolve_diff_base "$old_ref" "$new_ref")"
facts="$(scan_diff "$diff_base" "$new_ref")"
need="$(printf '%s\n' "$facts" | sed -n 's/^need=//p')"
fragments="$(printf '%s\n' "$facts" | sed -n 's/^fragments=//p')"
introduced="$(printf '%s\n' "$facts" | sed -n 's/^introduced=//p')"
edited="$(printf '%s\n' "$facts" | sed -n 's/^edited=//p')"
removed="$(printf '%s\n' "$facts" | sed -n 's/^removed=//p')"
anomaly="$(printf '%s\n' "$facts" | sed -n 's/^anomaly=//p')"
if [[ -z "$need" || -z "$fragments" || -z "$introduced" || -z "$edited" || -z "$removed" || -z "$anomaly" ]]; then
  die "could not read fragment scan"
  exit 1
fi
label="$(fetch_breaking_label)"
decide false "$need" "$label" "$fragments" "$introduced" "$edited" "$removed" "$anomaly"
