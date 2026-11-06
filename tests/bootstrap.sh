#!/bin/bash
# The bootstrap triple test (docs/history/bootstrap-plan.md, Phase C).
#
#   1. rice0, the installed rice (built by KiCS2), compiles Rice.Main into
#      rice1.
#   2. rice1 compiles Rice.Main again. The result is rice2.
#   Each compiler works in its own copy of the tree with no caches, so it
#   compiles Prelude and every library module itself. (The caches don't
#   know which compiler made them, so the working tree's could be stale.)
#   3. Every .c and .h rice1 generated must be byte-identical to rice0's.
#      A difference is a place where rice's own semantics differ from
#      KiCS2's on rice's source. (rice-main.c differs only in the home
#      directory it records, RICE_INSTALL_DIR, which is left out.)
#
# With --fixpoint, rice2 then compiles Rice.Main in a third copy, and its
# C must match rice1's.
#
# Usage: tests/bootstrap.sh [--fixpoint]
#
# Takes about 45 minutes (rice1 is slow), and over 4 GB of memory. The
# copies and logs go in tests/.bootstrap/.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/.bootstrap"
FIXPOINT=0
[ "${1:-}" = "--fixpoint" ] && FIXPOINT=1

RICE0="$(command -v rice || echo "$HOME/.cpm/bin/rice")"
mkdir -p "$OUT"

# The load path cypm builds rice with, under home directory $1.
load_path() {
  sed -n 's/^packageLoadPath = "\(.*\)"$/\1/p' "$ROOT/src/Rice/PackageConfig.curry" \
    | sed "s|$ROOT|$1|g"
}

# A copy of the tree at $1 with none of the caches, for a compiler to fill.
fresh_copy() {
  rm -rf "$1"
  mkdir -p "$1"
  rsync -a --exclude .git --exclude frontend --exclude 'tests/.*' \
        --exclude '.curry/' --exclude 'obj-*/' "$ROOT/" "$1/"
}

# Compiles Rice.Main with compiler $1 in home $2, and moves the result to $3.
build() {
  local compiler="$1" home="$2" result="$3" log="$4"
  echo "== $(basename "$result"): $(basename "$compiler") in $home"
  local start=$SECONDS
  ( cd "$home/src" && RICEHOME="$home" CURRYPATH="$(load_path "$home")" \
      "$compiler" -v Rice.Main ) > "$log" 2>&1
  local code=$?
  if [ $code -ne 0 ] || [ ! -x "$home/src/Rice.Main" ]; then
    echo "   failed (exit $code); see $log"
    exit 1
  fi
  mv "$home/src/Rice.Main" "$result"
  echo "   built in $((SECONDS - start)) s"
}

# Compares the generated C under homes $1 and $2.
compare() {
  local a="$1" b="$2" same=0 differ=0
  while read -r f; do
    if [ "$(basename "$f")" = rice-main.c ]; then
      if diff -q <(grep -v RICE_INSTALL_DIR "$a/$f") \
                 <(grep -v RICE_INSTALL_DIR "$b/$f") > /dev/null; then
        same=$((same + 1))
      else
        differ=$((differ + 1)); echo "   DIFF $f"
      fi
    elif [ ! -f "$a/$f" ]; then
      differ=$((differ + 1)); echo "   MISSING $f"
    elif cmp -s "$a/$f" "$b/$f"; then
      same=$((same + 1))
    else
      differ=$((differ + 1)); echo "   DIFF $f"
    fi
  done < <(cd "$b" && find . -path '*/.curry/rice-*' \( -name '*.c' -o -name '*.h' \) \
                         -not -path '*/obj-*' | sort)
  echo "   $same identical, $differ different"
  [ $differ -eq 0 ]
}

fresh_copy "$OUT/home0"
build "$RICE0" "$OUT/home0" "$OUT/rice1" "$OUT/rice1.log"

fresh_copy "$OUT/home1"
build "$OUT/rice1" "$OUT/home1" "$OUT/rice2" "$OUT/rice2.log"

echo "== rice0's C against rice1's"
compare "$OUT/home0" "$OUT/home1"
result=$?

if [ $FIXPOINT -eq 1 ]; then
  fresh_copy "$OUT/home2"
  build "$OUT/rice2" "$OUT/home2" "$OUT/rice3" "$OUT/rice3.log"
  echo "== rice1's C against rice2's"
  compare "$OUT/home1" "$OUT/home2" || result=1
fi

exit $result
