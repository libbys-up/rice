#!/bin/sh
# Prints the C compiler to build rice's C with, the same way rice chooses
# one (Rice.Main.findCCompiler):
#   1. $RICE_CC, if it's set;
#   2. the first of clang, clang-22, ..., clang-13 on $PATH;
#   3. $CC, if it's set in the environment;
#   4. gcc.
# Rice's C needs musttail: clang 13 or later, or gcc 15 or later.
if [ -n "${RICE_CC:-}" ]; then
  echo "$RICE_CC"
  exit 0
fi
for c in clang clang-22 clang-21 clang-20 clang-19 clang-18 clang-17 \
         clang-16 clang-15 clang-14 clang-13; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "$c"
    exit 0
  fi
done
if [ -n "${CC:-}" ]; then
  echo "$CC"
  exit 0
fi
if command -v gcc >/dev/null 2>&1; then
  echo gcc
  exit 0
fi
echo "No C compiler found. Rice needs clang 13 or later (or gcc 15 or later)." >&2
echo "Install one, or set RICE_CC to the compiler to use." >&2
exit 1
