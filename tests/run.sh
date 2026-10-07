#!/bin/bash
# Rice's test bench: compiles and runs every .curry program under
# tests/programs/ with `rice`, checking output against a golden
# <name>.expected file where one exists (exact match) and just requiring a
# clean, non-timing-out exit where one doesn't. Meant to run before commits
# -- see tests/README.md.
#
# Usage:
#   tests/run.sh [options] [name-substring ...]
#
# Options:
#   --slow        also run programs the manifest marks SLOW/XSLOW (longer
#                 timeout)
#   --record      write tests/programs/**/<name>.expected from actual output
#                 for any test that passes but has no golden file yet --
#                 review with `git diff` before committing it as a golden
#   --no-clean    skip the default full Prelude-cache wipe at start (faster
#                 reruns; only safe if replace/*.curry and runtime/*.c/h
#                 haven't changed since the last clean run)
#   -v, --verbose show each test's actual output as it runs
#
# name-substring, if given, filters to tests whose relative path contains
# any of the given substrings (e.g. `tests/run.sh regressions` or
# `tests/run.sh fib tak`).
#
# Exit code is nonzero iff at least one test FAILed (an unexpected
# compile/run/output-mismatch/timeout) -- XFAIL/XSLOW, SLOW-skipped, and
# no-golden-yet passes never affect it, so this is safe to wire into a
# pre-commit hook or CI step directly.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRAMS="$HERE/programs"
MANIFEST="$HERE/manifest.txt"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
resolve_ricehome
resolve_rice
SCRATCH="$HERE/.run"
COMPILE_TIMEOUT=60
RUN_TIMEOUT=15
SLOW_RUN_TIMEOUT=180

RUN_SLOW=0
RECORD=0
CLEAN=1
VERBOSE=0
FILTERS=()

for arg in "$@"; do
  case "$arg" in
    --slow) RUN_SLOW=1 ;;
    --record) RECORD=1 ;;
    --no-clean) CLEAN=0 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) FILTERS+=("$arg") ;;
  esac
done

if [ ! -x "$RICE" ]; then
  echo "run.sh: can't find a 'rice' executable (looked for \$PATH and ~/.cpm/bin/rice)" >&2
  exit 2
fi

if [ "$CLEAN" -eq 1 ]; then
  echo "Cleaning Prelude cache (\$RICEHOME/.curry, kics2 lib's rice-1.0.0 cache)..."
  rm -rf "$RICEHOME/.curry"
  # Rice.Build.Cache's mtime-based staleness check has no reason to know
  # about replace/*.curry (it's read fresh every compile, but the
  # *optimized-TProg* cache it guards doesn't track that file as a
  # dependency) -- so a `replace_Prelude.curry`/`replace_Prim.curry` edit
  # needs this wiped by hand to actually take effect, same as a `rice`
  # rebuild does. KICS2HOME (already exported in this project's own
  # .bashrc) is tried first; falls back to deriving it from `kics2` on
  # $PATH, and is a no-op (not a hard error) if neither resolves.
  KICS2_LIB="${KICS2HOME:-}"
  if [ -z "$KICS2_LIB" ] && command -v kics2 >/dev/null 2>&1; then
    KICS2_LIB="$(cd "$(dirname "$(command -v kics2)")/.." && pwd)"
  fi
  [ -n "$KICS2_LIB" ] && [ -d "$KICS2_LIB/lib/.curry/rice-1.0.0" ] && \
    rm -rf "$KICS2_LIB/lib/.curry/rice-1.0.0"
fi

mkdir -p "$SCRATCH"

pass=0; pass_unverified=0; fail=0; xfail=0; xpass=0; skip=0; slow_skip=0
fails_list=()
xpass_list=()

run_one() {
  local src="$1"
  local rel="${src#"$PROGRAMS"/}"
  matches_filter "$rel" || return

  local status reason
  status="$(manifest_status "$rel")"
  reason="$(manifest_reason "$rel")"

  if [ "$status" = "SKIP" ]; then
    skip=$((skip+1))
    [ "$VERBOSE" -eq 1 ] && echo "SKIP  $rel  ($reason)"
    return
  fi
  if { [ "$status" = "SLOW" ] || [ "$status" = "XSLOW" ]; } && [ "$RUN_SLOW" -eq 0 ]; then
    slow_skip=$((slow_skip+1))
    [ "$VERBOSE" -eq 1 ] && echo "SLOW  $rel  (skipped; use --slow)"
    return
  fi
  # XFAIL/XSLOW both mean "expected to fail, for a documented reason" --
  # XFAIL for a plain compile-time rejection, XSLOW for a large-input
  # benchmark expected to crash or time out once actually *run* (not
  # skipped outright like SLOW, since a run.sh invocation that does pass
  # --slow should still notice if one of these starts working, same
  # XPASS spirit as XFAIL). Distinguished from an ordinary failure below
  # at both the compile and the run stage.
  local expected_fail=0
  { [ "$status" = "XFAIL" ] || [ "$status" = "XSLOW" ]; } && expected_fail=1

  local name; name="$(basename "$src" .curry)"
  local work="$SCRATCH/${rel%.curry}"
  rm -rf "$work"; mkdir -p "$work"
  cp "$src" "$work/"

  local run_timeout=$RUN_TIMEOUT
  { [ "$status" = "SLOW" ] || [ "$status" = "XSLOW" ]; } && run_timeout=$SLOW_RUN_TIMEOUT

  local build_log="$work/build.log"
  # Mode is inferred straight from the test's own `main` signature, not
  # from a manifest entry: an `IO`-typed main compiles in Rice's default
  # "standalone executable" mode (run_io -- exactly once, no result
  # printed), anything else (most of the old_rice-derived corpus, written
  # in the older bare-goal style -- `main :: [Int]`, not `IO ()`, or with
  # no signature at all) needs `--interactive` (nf_all -- print every
  # solution) or it would just silently run and print nothing. This is
  # self-maintaining as tests are added/removed, unlike a manifest list
  # that would need to be kept in sync by hand.
  #
  # A test can override this inference with a `-- rice-mode: standalone`
  # or `-- rice-mode: interactive` comment anywhere in its source --
  # needed for the rare test that's deliberately checking the *other*
  # mode's behavior than its own main type would suggest (e.g. an `IO ()`
  # program specifically exercising nf_all's backtracking-retry loop,
  # which Rice's default standalone mode never even attempts).
  local mode_override
  mode_override="$(grep -m1 -oE 'rice-mode: (standalone|interactive)' "$src" | awk '{print $2}')"
  local flags=""
  if [ "$mode_override" = "interactive" ]; then
    flags="--interactive"
  elif [ "$mode_override" != "standalone" ]; then
    grep -qE '^main[[:space:]]*::.*\bIO\b' "$src" || flags="$flags --interactive"
  fi
  # RICE_CFLAGS (unset by default) passes through to `rice --cflags=...` --
  # e.g. `RICE_CFLAGS=-DOPT_COPY_COLLAPSE=1 tests/run.sh` to verify a
  # backtracking-optimizations.md toggle actually gets exercised, without
  # needing a second copy of this script. Built as a plain, unquoted-
  # expanded string rather than an array: bash 3.2 (macOS's stock
  # /bin/bash) treats `"${arr[@]}"` on an empty array as an
  # unbound-variable error under `set -u`, not an empty expansion the way
  # bash 4+ does -- and neither flag here can contain a space or glob
  # character, so word-splitting is safe.
  # One --cflags per word (it's repeatable): a single
  # `--cflags=$RICE_CFLAGS` would be word-split here, handing rice a bare
  # `-DOPT_...` for any flag after the first.
  for cf in ${RICE_CFLAGS:-}; do flags="$flags --cflags=$cf"; done
  # Every module that gets regenerated is checked for raw values that
  # could reach a pointer slot (src/field-reps-plan.md); a lint failure is
  # a compile failure.
  flags="$flags --lint-fieldreps"
  # `-- rice-flags: <flags>` anywhere in the source adds compiler flags for
  # that one test (e.g. `--debug=high`, or `--cflags=-DCHECK_LAYOUT=1`).
  local extra_flags
  extra_flags="$(grep -m1 -oE 'rice-flags: .*' "$src" | sed 's/^rice-flags: //')"
  flags="$flags $extra_flags"
  # `-- rice-exit: N` says the program is *meant* to exit with status N
  # (e.g. a runtime error being tested); its output, stderr included, is
  # still checked against the golden.
  local want_exit
  want_exit="$(grep -m1 -oE 'rice-exit: [0-9]+' "$src" | awk '{print $2}')"
  want_exit="${want_exit:-0}"
  # `-- rice-golden: none` checks only that the program runs and exits as
  # expected -- for output that legitimately changes with any codegen
  # change, like a --debug trace.
  local no_golden=0
  grep -qE 'rice-golden: none' "$src" && no_golden=1
  ( cd "$work" && timeout "$COMPILE_TIMEOUT" "$RICE" $flags "$name.curry" ) >"$build_log" 2>&1
  local build_ok=0
  [ -x "$work/$name" ] && build_ok=1

  if [ "$build_ok" -ne 1 ]; then
    if [ "$expected_fail" -eq 1 ]; then
      xfail=$((xfail+1))
      [ "$VERBOSE" -eq 1 ] && echo "XFAIL $rel  ($reason)"
    else
      fail=$((fail+1))
      fails_list+=("$rel (compile failed -- see $build_log)")
      echo "FAIL  $rel  (compile failed)"
      [ "$VERBOSE" -eq 1 ] && tail -20 "$build_log" | sed 's/^/      /'
    fi
    return
  fi

  local out_log="$work/out.log"
  ( cd "$work" && timeout "$run_timeout" "./$name" ) >"$out_log" 2>&1
  local run_code=$?

  if [ "$run_code" -eq 124 ] || [ "$run_code" -eq 137 ]; then
    if [ "$expected_fail" -eq 1 ]; then
      xfail=$((xfail+1))
      [ "$VERBOSE" -eq 1 ] && echo "XFAIL $rel  (timed out as expected: $reason)"
    else
      fail=$((fail+1))
      fails_list+=("$rel (timed out after ${run_timeout}s running)")
      echo "FAIL  $rel  (timed out after ${run_timeout}s)"
    fi
    return
  fi
  # Any other non-zero exit is a crash (segfault, abort, ...) -- checked
  # explicitly, not folded into the timeout check above: a run that just
  # exits non-zero without timing out used to fall straight through to the
  # golden-comparison/record logic below and get reported as an ordinary
  # PASS whenever no golden existed yet, silently hiding a real crash
  # (caught for real: three old_rice benchmarks segfaulting in
  # print_final, all reported PASS by a version of this script without
  # this check).
  if [ "$run_code" -ne "$want_exit" ]; then
    if [ "$expected_fail" -eq 1 ]; then
      xfail=$((xfail+1))
      [ "$VERBOSE" -eq 1 ] && echo "XFAIL $rel  (crashed as expected, exit code $run_code: $reason)"
    else
      fail=$((fail+1))
      fails_list+=("$rel (exit code $run_code, expected $want_exit -- see $out_log)")
      echo "FAIL  $rel  (exit code $run_code, expected $want_exit)"
      [ "$VERBOSE" -eq 1 ] && tail -20 "$out_log" | sed 's/^/      | /'
    fi
    return
  fi

  if [ "$expected_fail" -eq 1 ]; then
    xpass=$((xpass+1))
    xpass_list+=("$rel (expected to fail: $reason)")
    echo "XPASS $rel  -- ran clean; consider removing its manifest entry"
    # fall through: still check/record its output like a normal test.
  fi

  [ "$VERBOSE" -eq 1 ] && sed 's/^/      | /' "$out_log"

  # `nf_all`'s trailing "total memory allocations: N" line reflects
  # allocator/optimizer behavior, not program correctness -- it can
  # legitimately drift on a perfectly good change (e.g. inlining removing
  # an allocation), so it's stripped before comparing/recording rather
  # than baked into the golden, to keep goldens catching real regressions
  # instead of flagging every allocation-count shift as one.
  local out_filtered="$work/out.filtered"
  grep -v '^total memory allocations:' "$out_log" > "$out_filtered"

  if [ "$no_golden" -eq 1 ]; then
    pass=$((pass+1))
    [ "$VERBOSE" -eq 1 ] && echo "PASS  $rel  (rice-golden: none -- exit status only)"
    return
  fi

  local golden="$src"; golden="${golden%.curry}.expected"
  if [ -f "$golden" ]; then
    if diff -q "$golden" "$out_filtered" >/dev/null 2>&1; then
      pass=$((pass+1))
      [ "$VERBOSE" -eq 1 ] && echo "PASS  $rel"
    else
      fail=$((fail+1))
      fails_list+=("$rel (output != $golden -- diff $golden $out_filtered)")
      echo "FAIL  $rel  (output mismatch)"
      [ "$VERBOSE" -eq 1 ] && diff "$golden" "$out_filtered" | sed 's/^/      /'
    fi
  else
    if [ "$RECORD" -eq 1 ]; then
      cp "$out_filtered" "$golden"
      pass=$((pass+1))
      echo "PASS  $rel  (recorded new golden: $golden)"
    else
      pass_unverified=$((pass_unverified+1))
      echo "PASS  $rel  (ran clean, no golden yet -- rerun with --record to save one)"
    fi
  fi
}

while IFS= read -r -d '' f; do
  run_one "$f"
done < <(find "$PROGRAMS" -name '*.curry' -print0 | sort -z)

echo
echo "== Summary =="
echo "pass (verified against golden): $pass"
echo "pass (no golden yet):           $pass_unverified"
echo "fail:                           $fail"
echo "xfail (expected, pre-existing): $xfail"
echo "xpass (unexpectedly compiles/runs): $xpass"
echo "skip (not meant to run):        $skip"
echo "slow (skipped, use --slow):     $slow_skip"

if [ "${#fails_list[@]}" -gt 0 ]; then
  echo
  echo "Failures:"
  for f in "${fails_list[@]}"; do echo "  - $f"; done
fi
if [ "${#xpass_list[@]}" -gt 0 ]; then
  echo
  echo "Unexpected passes (manifest says XFAIL/XSLOW, but it worked):"
  for f in "${xpass_list[@]}"; do echo "  - $f"; done
fi

[ "$fail" -eq 0 ]
