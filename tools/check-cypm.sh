#!/bin/sh
# Checks that the cypm given ($1) belongs to KiCS2, which rice is built
# with. A PAKCS-built rice compiles but fails on every program.
# Used by the Makefile's `rice` target.
cypm="${1:-cypm}"
version="$("$cypm" config 2>/dev/null | sed -n 's/^Compiler version *: *//p')"
case "$version" in
  kics2*)
    exit 0
    ;;
  "")
    echo "make rice: can't run '$cypm'. Rice is built with KiCS2:" >&2
    ;;
  *)
    echo "make rice: '$cypm' is the cypm of $version, but rice is built with KiCS2:" >&2
    ;;
esac
echo "  make CYPM=/path/to/kics2/bin/cypm" >&2
exit 1
