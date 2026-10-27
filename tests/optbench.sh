#!/bin/bash
# The backtracking-optimization bench: how much each of #1-#5 and path
# compression (backtracking_proofs.md, src/backtracking-optimizations.md)
# actually buys, and on what. tests/bench.sh times the SLOW benchmarks under a few configs;
# this one is built around the optimizations instead:
#
#  * Configs isolate each optimization two ways: added alone to the naive
#    floor ("+x": what it does by itself), and removed from all-on ("-x":
#    what it still adds once the others are on). The difference between
#    the two is the interaction. See CONFIGS below.
#  * Every program is built twice per config: once plain, for wall-clock
#    time, and once with -DOPT_STATS=1, for exact event counts (trail
#    entries, entries each filter skipped, scoped-retry hits, copies,
#    forward hops, compressions, ...; runtime.h's OptStats). The counts
#    are deterministic, so they show an effect too small to time.
#  * Timing happens after every config is built, in rounds: each round
#    times every (program, config) once, in a rotated config order, so
#    load on the machine spreads across configs instead of landing on
#    one config's column. A measurement repeats a short program until
#    --min-time has passed and reports the time per run. The report has
#    the minimum over rounds, and the spread (max/min) as a noise check.
#  * It's also a differential test: every config's output must match the
#    program's .expected golden. A mismatch is reported and makes the exit
#    code nonzero. A program without a golden isn't run at all.
#
# Usage:
#   tests/optbench.sh [options] [name-substring ...]
#
# Options:
#   --runs=N        timing rounds; the minimum is kept (default 3)
#   --min-time=SEC  repeat a program within a measurement until this much
#                   time has passed (default 0.5)
#   --timeout=SEC   per-run timeout (default 120)
#   --max-mem=MB    kill a run whose resident memory passes this (default
#                   4096). Configs with neither #1 nor #5 trail every
#                   rewrite, choice point or not, and on a big
#                   deterministic program the trail grows without bound.
#   --configs=LIST  comma-separated config names to run (default: all)
#   --sets=LIST     comma-separated program sets to run (default: all;
#                   see SETS below)
#   --no-time       skip the timed builds; counts and correctness only
#   --out=DIR       where results go (default tests/.optbench)
#
# Programs: every program with a .expected golden in the selected sets
# (SETS below). optbench/ has one program per optimization (its header
# comment says which and why); the others are the benchmark suites of
# old_rice, KiCS2 and PAKCS's examples.
#
# Results: DIR/results.tsv (one row per program, config, metric),
# DIR/samples.tsv (every timing measurement) and DIR/report.md (the
# tables).
#
# Builds: each program has one source directory (DIR/src) that every
# config rebuilds in, and each build's binary is copied out. rice skips
# its frontend when the generated C is up to date, so the Curry-to-C
# step runs once per program; a change of flags only recompiles the C.
# Builds go config by config, because a change of flags rebuilds
# runtime/*.o and the Prelude object, and that's most of the build time.
# For the same reason, don't run this at the same time as another rice
# build with different flags (tests/README.md).

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRAMS="$HERE/programs"
MANIFEST="$HERE/manifest.txt"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
resolve_ricehome
resolve_rice

RUNS=3
MIN_TIME=0.5
RUN_TIMEOUT=120
MAX_MEM_MB=4096
COMPILE_TIMEOUT=300
ONLY_CONFIGS=""
ONLY_SETS=""
TIMED=1
OUT="$HERE/.optbench"
FILTERS=()

for arg in "$@"; do
  case "$arg" in
    --runs=*)    RUNS="${arg#--runs=}" ;;
    --min-time=*) MIN_TIME="${arg#--min-time=}" ;;
    --timeout=*) RUN_TIMEOUT="${arg#--timeout=}" ;;
    --max-mem=*) MAX_MEM_MB="${arg#--max-mem=}" ;;
    --configs=*) ONLY_CONFIGS="${arg#--configs=}" ;;
    --sets=*)    ONLY_SETS="${arg#--sets=}" ;;
    --no-time)   TIMED=0 ;;
    --out=*)     OUT="${arg#--out=}" ;;
    -h|--help)   sed -n '2,62p' "$0"; exit 0 ;;
    *)           FILTERS+=("$arg") ;;
  esac
done

# --- configs. Flags: NT = OPT_NONDET_TRAIL (#1), SB = OPT_SCOPED_BACKTRACK
# (#3), CC = OPT_COPY_COLLAPSE (#4), ET = OPT_EPOCH_TRAIL (#5), PC =
# OPT_PATH_COMPRESS, TD = OPT_TAIL_DISPATCH (#2). The write barrier
# follows runtime.h's default: on exactly when NT and ET both are.
# `+epoch+barrier` turns it on with ET alone, to measure what the barrier
# costs #5 by itself.
flags_of() {  # NT SB CC ET PC TD [extra]
  echo "-DOPT_NONDET_TRAIL=$1 -DOPT_SCOPED_BACKTRACK=$2 -DOPT_COPY_COLLAPSE=$3 -DOPT_EPOCH_TRAIL=$4 -DOPT_PATH_COMPRESS=$5 -DOPT_TAIL_DISPATCH=$6 ${7:-}"
}
CONFIGS=(
  "naive|$(flags_of 0 0 0 0 0 0)"
  "+nondet|$(flags_of 1 0 0 0 0 0)"
  "+tail|$(flags_of 0 0 0 0 0 1)"
  "+scoped|$(flags_of 0 1 0 0 0 0)"
  "+copy|$(flags_of 0 0 1 0 0 0)"
  "+epoch|$(flags_of 0 0 0 1 0 0)"
  "+compress|$(flags_of 0 0 0 0 1 0)"
  "+epoch+barrier|$(flags_of 0 0 0 1 0 0 -DOPT_WRITE_BARRIER=1)"
  "+nondet+epoch|$(flags_of 1 0 0 1 0 0)"
  "default|$(flags_of 1 1 0 0 0 1)"
  "all|$(flags_of 1 1 1 1 1 1)"
  "-nondet|$(flags_of 0 1 1 1 1 1)"
  "-tail|$(flags_of 1 1 1 1 1 0)"
  "-scoped|$(flags_of 1 0 1 1 1 1)"
  "-copy|$(flags_of 1 1 0 1 1 1)"
  "-epoch|$(flags_of 1 1 1 0 1 1)"
  "-compress|$(flags_of 1 1 1 1 0 1)"
)

# --- program sets: name|directory under tests/programs.
SETS=(
  "optbench|optbench"
  "old_rice|old_rice/benchmarks"
  "kics2|kics2_bench"
  "pakcs|pakcs_examples"
)

PROGRAM_LIST=()
for entry in "${SETS[@]}"; do
  sname="${entry%%|*}"; sdir="${entry#*|}"
  if [ -n "$ONLY_SETS" ] && ! echo ",$ONLY_SETS," | grep -qF ",$sname,"; then
    continue
  fi
  for f in "$PROGRAMS/$sdir"/*.curry; do
    [ -f "${f%.curry}.expected" ] && PROGRAM_LIST+=("$f")
  done
done
SELECTED=()
for f in "${PROGRAM_LIST[@]}"; do
  matches_filter "${f#"$PROGRAMS"/}" && SELECTED+=("$f")
done
if [ "${#SELECTED[@]}" -eq 0 ]; then
  echo "optbench.sh: no programs matched" >&2
  exit 2
fi

mkdir -p "$OUT"
# Fresh sources each run, so C generated by an older rice isn't reused.
rm -rf "$OUT/src"
RESULTS="$OUT/results.tsv"
SAMPLES="$OUT/samples.tsv"
: > "$RESULTS"
: > "$SAMPLES"
mismatches=0

now_s() { perl -MTime::HiRes=time -e 'printf "%.6f", time'; }

# run_capped BIN OUT ERR: run BIN in its own directory, killing it after
# RUN_TIMEOUT seconds or once its resident memory passes MAX_MEM_MB
# (macOS ignores ulimit -v, so a watchdog polls ps). Returns the exit
# code, 124 on a timeout, or 125 on running out of memory. The caller
# waits on the program itself, so the polling doesn't delay a timing.
run_capped() {
  local bin="$1" out="$2" err="$3" pid wpid code flag
  flag="$(dirname "$bin")/.killed"
  rm -f "$flag"
  ( cd "$(dirname "$bin")" && exec "$bin" ) > "$out" 2> "$err" &
  pid=$!
  (
    limit=$((MAX_MEM_MB * 1024)); start=$(date +%s)
    while kill -0 "$pid" 2> /dev/null; do
      rss="$(ps -o rss= -p "$pid" 2> /dev/null | tr -d ' ')"
      if [ -n "$rss" ] && [ "$rss" -gt "$limit" ]; then
        echo memout > "$flag"; kill -9 "$pid" 2> /dev/null; exit 0
      fi
      if [ $(( $(date +%s) - start )) -ge "$RUN_TIMEOUT" ]; then
        echo timeout > "$flag"; kill -9 "$pid" 2> /dev/null; exit 0
      fi
      sleep 0.2
    done
  ) &
  wpid=$!
  wait "$pid" 2> /dev/null; code=$?
  kill "$wpid" 2> /dev/null; wait "$wpid" 2> /dev/null
  if [ -f "$flag" ]; then
    [ "$(cat "$flag")" = memout ] && code=125 || code=124
    rm -f "$flag"
  fi
  return "$code"
}

# build CONFIG FLAGS SRC KIND -> prints the binary's path, or nothing.
# Builds in the program's source directory, then copies the binary to
# DIR/build/KIND/CONFIG/<program>/, where it's run.
build() {
  local cname="$1" flags="$2" src="$3" kind="$4"
  local rel="${src#"$PROGRAMS"/}" name; name="$(basename "$src" .curry)"
  local work="$OUT/src/${rel%.curry}"
  local dest="$OUT/build/$kind/$cname/${rel%.curry}"
  mkdir -p "$work" "$dest"
  # Only when it's new, so the copy's mtime doesn't make rice redo its frontend.
  cmp -s "$src" "$work/$name.curry" || cp "$src" "$work/"
  rm -f "$work/$name" "$dest/$name"
  local mode=""
  grep -qE '^main[[:space:]]*::.*\bIO\b' "$src" || mode="--interactive"
  ( cd "$work" && timeout "$COMPILE_TIMEOUT" "$RICE" $mode --cflags="$flags" "$name.curry" ) \
    > "$dest/build.log" 2>&1
  [ -x "$work/$name" ] || return 0
  cp "$work/$name" "$dest/$name"
  echo "$dest/$name"
}

row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; }

echo "optbench: RICE=$RICE, ${#SELECTED[@]} programs, results in $OUT"
for entry in "${CONFIGS[@]}"; do
  cname="${entry%%|*}"; flags="${entry#*|}"
  if [ -n "$ONLY_CONFIGS" ] && ! echo ",$ONLY_CONFIGS," | grep -qF ",$cname,"; then
    continue
  fi
  echo "== $cname: $flags"
  for src in "${SELECTED[@]}"; do
    rel="${src#"$PROGRAMS"/}"
    golden="${src%.curry}.expected"

    # Counts, and the output to check.
    bin="$(build "$cname" "$flags -DOPT_STATS=1" "$src" stats)"
    if [ -z "$bin" ]; then
      echo "   $rel: BUILD FAIL (see $OUT/build/stats/$cname/${rel%.curry}/build.log)"
      row "$rel" "$cname" status buildfail
      continue
    fi
    out="$(dirname "$bin")/out"
    run_capped "$bin" "$out" "$out.stats"
    code=$?
    if [ "$code" -ne 0 ]; then
      case "$code" in
        124) st=timeout ;;
        125) st=memout ;;
        *)   st="exit$code" ;;
      esac
      echo "   $rel: $st"
      row "$rel" "$cname" status "$st"
      continue
    fi
    grep -v '^total memory allocations:' "$out" > "$out.clean"
    status=ok
    if ! cmp -s "$golden" "$out.clean"; then
      status=MISMATCH
      mismatches=$((mismatches+1))
      echo "   $rel: OUTPUT MISMATCH against $golden"
    fi
    row "$rel" "$cname" status "$status"
    awk '$1=="stat" {print $2"\t"$3}' "$out.stats" | while IFS=$'\t' read -r k v; do
      row "$rel" "$cname" "$k" "$v"
    done
  done

  # The timed builds, in a second pass, so the flags change only once
  # per pass. They're timed after every config is built.
  [ "$TIMED" -eq 1 ] || continue
  for src in "${SELECTED[@]}"; do
    rel="${src#"$PROGRAMS"/}"
    if [ -z "$(build "$cname" "$flags" "$src" time)" ]; then
      echo "   $rel: timed build failed"
      row "$rel" "$cname" seconds NA
    fi
  done
done

# measure BIN REPS -> seconds per run over REPS runs, or nothing if a run failed
measure() {
  local bin="$1" reps="$2" t0 t1 i
  t0="$(now_s)"
  for i in $(seq 1 "$reps"); do
    run_capped "$bin" /dev/null /dev/null || return 0
  done
  t1="$(now_s)"
  perl -e "printf '%.4f', ($t1 - $t0) / $reps"
}

# The configs that were selected and built, in CONFIGS order.
TIMED_CONFIGS=()
for entry in "${CONFIGS[@]}"; do
  cname="${entry%%|*}"
  if [ -z "$ONLY_CONFIGS" ] || echo ",$ONLY_CONFIGS," | grep -qF ",$cname,"; then
    TIMED_CONFIGS+=("$cname")
  fi
done
nconf=${#TIMED_CONFIGS[@]}

if [ "$TIMED" -eq 1 ]; then
  for round in $(seq 1 "$RUNS"); do
    echo "== timing round $round of $RUNS"
    for src in "${SELECTED[@]}"; do
      rel="${src#"$PROGRAMS"/}"; name="$(basename "$src" .curry)"
      line="   $rel:"
      for k in $(seq 0 $((nconf - 1))); do
        # Rotate the starting config each round (and per program).
        cname="${TIMED_CONFIGS[$(( (k + round + ${#rel}) % nconf ))]}"
        bin="$OUT/build/time/$cname/${rel%.curry}/$name"
        [ -x "$bin" ] || continue
        # Not if it failed in the stats pass: it would just fail again.
        grep -qF "$rel	$cname	status	ok" "$RESULTS" || continue
        # Repetitions: picked in the first round from one run's time, so
        # that a measurement takes at least MIN_TIME. The run before that
        # is thrown away: a freshly linked binary's first run is slow
        # (macOS checks it on first launch; disk caches are cold).
        repf="$(dirname "$bin")/reps"
        if [ ! -f "$repf" ]; then
          measure "$bin" 1 > /dev/null
          t="$(measure "$bin" 1)"
          [ -n "$t" ] || { echo "   $rel under $cname: run failed"; continue; }
          perl -e "use POSIX; my \$r = ceil($MIN_TIME / ($t > 0 ? $t : 0.001)); print((\$r < 1 ? 1 : \$r > 200 ? 200 : \$r), qq(\n))" > "$repf"
        fi
        t="$(measure "$bin" "$(cat "$repf")")"
        [ -n "$t" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$rel" "$cname" "$round" "$t" >> "$SAMPLES"
        line="$line $cname=$t"
      done
      echo "$line"
    done
  done
  # The minimum and the spread (max/min) of each (program, config).
  awk -F'\t' '{ k = $1 "\t" $2
                 if (!(k in lo) || $4 < lo[k]) lo[k] = $4
                 if (!(k in hi) || $4 > hi[k]) hi[k] = $4 }
               END { for (k in lo) {
                       printf "%s\tseconds\t%.3f\n", k, lo[k]
                       printf "%s\tspread\t%.2f\n", k, (lo[k] > 0 ? hi[k] / lo[k] : 0) } }' \
    "$SAMPLES" >> "$RESULTS"
fi

python3 -I "$HERE/optbench_report.py" "$RESULTS" > "$OUT/report.md"
echo
echo "Report: $OUT/report.md"
[ "$mismatches" -eq 0 ] || { echo "$mismatches output mismatch(es)"; exit 1; }
