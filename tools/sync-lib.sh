#!/bin/bash
# Copies KiCS2's standard library (the .curry sources only) into lib/,
# renaming the __KICS2__ CPP symbol to __RICE__. Rice's runtime implements
# the externals of the KiCS2 branches, and the front end is called with
# -D__RICE__ (Rice.Frontend), so rice compiles exactly what KiCS2 does.
#
# Usage: tools/sync-lib.sh [KICS2_HOME]   (default: kics2 on PATH)
#
# Afterwards, review `git diff lib/`, and note the KiCS2 version in
# lib/VERSION. A changed Prelude may need runtime/prelude.c or
# replace/*.curry updated to match.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib"

if [ $# -ge 1 ]; then
  KICS2_HOME="$1"
else
  KICS2_HOME="$(cd "$(dirname "$(command -v kics2)")/.." && pwd)"
fi
SRC="$KICS2_HOME/lib"
[ -f "$SRC/Prelude.curry" ] || { echo "no Prelude.curry in $SRC" >&2; exit 1; }

# Start over, so modules KiCS2 dropped don't linger. lib/.curry is the
# compiled cache, and goes too.
rm -rf "$LIB"
mkdir -p "$LIB"
( cd "$SRC" && find . -type f -name '*.curry' -not -path '*/.curry/*' ) | while read -r f; do
  mkdir -p "$LIB/$(dirname "$f")"
  sed 's/__KICS2__/__RICE__/g' "$SRC/$f" > "$LIB/$f"
done
echo "base $(cat "$SRC/VERSION"), from KiCS2 $("$KICS2_HOME/bin/kics2" --numeric-version)" > "$LIB/VERSION"
echo "Copied $(find "$LIB" -name '*.curry' | wc -l | tr -d ' ') modules into lib/"
