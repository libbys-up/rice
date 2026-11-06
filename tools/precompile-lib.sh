#!/bin/sh
# Compiles every module in rice's standard library (lib/), to C and
# objects (rice --no-link), so a program that uses one doesn't compile it
# the first time, and nothing has to be written into the installation
# afterwards. A module rice can't compile yet (its externals aren't
# implemented) is listed and skipped.
#
# Usage: tools/precompile-lib.sh RICE RICEHOME
set -u
RICE="$1"
HOME_DIR="$2"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ok=0
skipped=""
for f in $(cd "$HOME_DIR/lib" && find . -type f -name '*.curry' -not -path '*/.curry/*' | sort); do
  m="$(echo "$f" | sed 's|^\./||; s|\.curry$||; s|/|.|g')"
  [ "$m" = AllLibraries ] && continue
  # From an empty directory, so the module is found in lib/.
  if ( cd "$tmp" && RICEHOME="$HOME_DIR" "$RICE" --no-link "$m" ) > "$tmp/log" 2>&1; then
    ok=$((ok + 1))
  else
    skipped="$skipped $m"
  fi
done
echo "Compiled $ok library modules."
if [ -n "$skipped" ]; then
  echo "Not supported yet:$skipped"
fi
