#!/bin/sh
# Frozen declared-input probe (sha256sum). Golden tests compare this with the Julia helper.
set -eu
q=$1
do_hash=$2
if [ ! -e "$q" ] && [ ! -L "$q" ]; then printf '%s\n' missing; exit 2; fi
if [ -L "$q" ]; then
  _f=$q
  _linklen=$(stat -c '%s' "$_f" 2>/dev/null || stat -f '%z' "$_f") || exit 1
  _target=$(readlink "$_f") || exit 1
  _got=$(printf '%s' "$_target" | wc -c | tr -d ' ')
  [ "$_got" -eq "$_linklen" ] || {
    printf '%s\n' 'input link target contains a newline'
    exit 2
  }
  printf '%s' "$_target" | awk 'BEGIN { bad = 0 } index($0, "\t") { bad = 1 } END { if (NR > 1 || bad) exit 2 }' || {
    printf '%s\n' 'input link target contains a newline'
    exit 2
  }
fi
_dsk_hex() {
  _line=
  if command -v sha256sum >/dev/null 2>&1; then
    _line=$(sha256sum "$1") || return 1
  else
    _line=$(shasum -a 256 "$1") || return 1
  fi
  _hex=$(printf '%s\n' "$_line" | awk '{ print $1; exit }')
  printf '%s' "$_hex" | awk 'length($0)==64 && $0 ~ /^[0-9a-fA-F]+$/ { found=1 } END { exit found ? 0 : 1 }' || return 1
  printf '%s\n' "$_hex"
}
_dsk_stat() {
  stat -c '%s %Y' "$1" 2>/dev/null && return 0
  stat -f '%z %m' "$1"
}
if [ -d "$q" ]; then
  _paths=$(mktemp)
  _sorted=$(mktemp)
  _rows=$(mktemp)
  trap 'rm -f "$_paths" "$_sorted" "$_rows"' EXIT
  cd "$q" || exit 1
  find . '(' -type f -o -type l ')' -path '*
*' -print -quit > "$_paths" || exit 1
  if [ -s "$_paths" ]; then
    printf '%s\n' 'input filename contains a newline'
    exit 2
  fi
  find . -type f > "$_paths" || exit 1
  find . -type l >> "$_paths" || exit 1
  LC_ALL=C sort -o "$_sorted" "$_paths" || exit 1
  : > "$_rows"
  if [ "$do_hash" = 1 ]; then
    _total=0
    while IFS= read -r _f; do
      [ -n "$_f" ] || continue
      [ -L "$_f" ] && continue
      _st=$(_dsk_stat "$_f") || exit 1
      _size=$(printf '%s\n' "$_st" | awk '{ print $1; exit }')
      [ -n "$_size" ] || exit 1
      _total=$((_total + _size))
    done < "$_sorted"
    _done=0
    while IFS= read -r _f; do
      [ -n "$_f" ] || continue
      _rel=${_f#./}
      if [ -L "$_f" ]; then
        _linklen=$(stat -c '%s' "$_f" 2>/dev/null || stat -f '%z' "$_f") || exit 1
        _target=$(readlink "$_f") || exit 1
        _got=$(printf '%s' "$_target" | wc -c | tr -d ' ')
        [ "$_got" -eq "$_linklen" ] || {
          printf '%s\n' 'input link target contains a newline'
          exit 2
        }
        printf '%s' "$_target" | awk 'BEGIN { bad = 0 } index($0, "\t") { bad = 1 } END { if (NR > 1 || bad) exit 2 }' || {
          printf '%s\n' 'input link target contains a newline'
          exit 2
        }
        printf 'link\t%s\t%s\n' "$_target" "$_rel"
      else
        _st=$(_dsk_stat "$_f") || exit 1
        _size=$(printf '%s\n' "$_st" | awk '{ print $1; exit }')
        [ -n "$_size" ] || exit 1
        _hex=$(_dsk_hex "$_f") || exit 1
        _done=$((_done + _size))
        printf 'file\t%s\t%s\t%s\n' "$_size" "$_hex" "$_rel"
        printf 'PROG %s %s\n' "$_done" "$_total" >&2
      fi
    done < "$_sorted"
  else
    _files=0
    _bytes=0
    _newest=0
    while IFS= read -r _f; do
      [ -n "$_f" ] || continue
      _rel=${_f#./}
      _st=$(_dsk_stat "$_f") || exit 1
      _size=$(printf '%s\n' "$_st" | awk '{ print $1; exit }')
      _mtime=$(printf '%s\n' "$_st" | awk '{ print $2; exit }')
      [ -n "$_size" ] && [ -n "$_mtime" ] || exit 1
      if [ -L "$_f" ]; then
        _linklen=$(stat -c '%s' "$_f" 2>/dev/null || stat -f '%z' "$_f") || exit 1
        _target=$(readlink "$_f") || exit 1
        _got=$(printf '%s' "$_target" | wc -c | tr -d ' ')
        [ "$_got" -eq "$_linklen" ] || {
          printf '%s\n' 'input link target contains a newline'
          exit 2
        }
        printf '%s' "$_target" | awk 'BEGIN { bad = 0 } index($0, "\t") { bad = 1 } END { if (NR > 1 || bad) exit 2 }' || {
          printf '%s\n' 'input link target contains a newline'
          exit 2
        }
        printf '%s\tlink\t%s\t%s\t%s\n' "$_rel" "$_size" "$_mtime" "$_target" >> "$_rows" || exit 1
      else
        _files=$((_files + 1))
        _bytes=$((_bytes + _size))
        printf '%s\tfile\t%s\t%s\n' "$_rel" "$_size" "$_mtime" >> "$_rows" || exit 1
      fi
      if [ "$_mtime" -gt "$_newest" ]; then _newest=$_mtime; fi
    done < "$_sorted"
    _sum=$(_dsk_hex "$_rows") || exit 1
    printf 'files=%s bytes=%s newest=%s digest=%s\n' "$_files" "$_bytes" "$_newest" "$_sum"
  fi
elif [ -f "$q" ]; then
  if [ "$do_hash" = 1 ] && [ -L "$q" ]; then
    printf 'link\t%s\t.\n' "$_target"
  elif [ "$do_hash" = 1 ]; then
    _st=$(_dsk_stat "$q") || exit 1
    _size=$(printf '%s\n' "$_st" | awk '{ print $1; exit }')
    [ -n "$_size" ] || exit 1
    _sum=$(_dsk_hex "$q") || exit 1
    printf 'PROG %s %s\n' "$_size" "$_size" >&2
    printf 'file\t%s\t%s\t.\n' "$_size" "$_sum"
  else
    _st=$(_dsk_stat "$q") || exit 1
    _size=$(printf '%s\n' "$_st" | awk '{ print $1; exit }')
    _mtime=$(printf '%s\n' "$_st" | awk '{ print $2; exit }')
    [ -n "$_size" ] && [ -n "$_mtime" ] || exit 1
    _one=$(mktemp)
    trap 'rm -f "$_one"' EXIT
    printf '.\tfile\t%s\t%s\n' "$_size" "$_mtime" > "$_one"
    _sum=$(_dsk_hex "$_one") || exit 1
    printf 'files=1 bytes=%s newest=%s digest=%s\n' "$_size" "$_mtime" "$_sum"
  fi
else
  printf '%s\n' 'not a file or directory'
  exit 2
fi
