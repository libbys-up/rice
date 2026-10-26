#!/bin/bash
# The backtracking-optimization bench: how much each of #1, #3, #4, #5
# and path compression (backtracking_proofs.md) actually buys, and on
# what. tests/bench.sh times the SLOW benchmarks under a few configs;
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
#    program's .expected golden (or, without one, the naive config's
#    output). A mismatch is reported and makes the exit code nonzero.
#
# Usage:
#   tests/optbench.sh [options] [name-substring ...]
#
# Options:
#   --runs=N        timing rounds; the minimum is kept (default 3)
#   --min-time=SEC  repeat a program within a measurement until this much
#                   time has passed (default 0.5)
#   --timeout=SEC   per-run timeout (default 120)
#   --configs=LIST  comma-separated config names to run (default: all)
#   --no-time       skip the timed builds; counts and correctness only
#   --out=DIR       where results go (default tests/.optbench)
#
# Programs: tests/programs/optbench/*.curry (each one targets one
# optimization; its header comment says which and why), plus the
# nondeterministic old_rice benchmarks listed in EXTRA below.
#
# Results: DIR/results.tsv (one row per program, config, metric),
# DIR/samples.tsv (every timing measurement) and DIR/report.md (the
# tables). Builds go config by config, because a change of flags
# rebuilds runtime/*.o and the Prelude object, and that's most of the
# build time. For the same reason, don't run this at the same time as
# another rice build with different flags (tests/README.md).

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
COMPILE_TIMEOUT=300
ONLY_CONFIGS=""
TIMED=1
OUT="$HERE/.optbench"
FILTERS=()

for arg in "$@"; do
  case "$arg" in
    --runs=*)    RUNS="${arg#--runs=}" ;;
    --min-time=*) MIN_TIME="${arg#--min-time=}" ;;
    --timeout=*) RUN_TIMEOUT="${arg#--timeout=}" ;;
    --configs=*) ONLY_CONFIGS="${arg#--configs=}" ;;
    --no-time)   TIMED=0 ;;
    --out=*)     OUT="${arg#--out=}" ;;
    -h|--help)   sed -n '2,50p' "$0"; exit 0 ;;
    *)           FILTERS+=("$arg") ;;
  esac
done

# --- configs. Flags: NT = OPT_NONDET_TRAIL (#1), SB = OPT_SCOPED_BACKTRACK
# (#3), CC = OPT_COPY_COLLAPSE (#4), ET = OPT_EPOCH_TRAIL (#5), PC =
# OPT_PATH_COMPRESS. The write barrier follows runtime.h's default: on
# exactly when NT and ET both are. `+epoch+barrier` turns it on with ET
# alone, to measure what the barrier costs #5 by itself.
flags_of() {  # NT SB CC ET PC [extra]
  echo "-DOPT_NONDET_TRAIL=$1 -DOPT_SCOPED_BACKTRACK=$2 -DOPT_COPY_COLLAPSE=$3 -DOPT_EPOCH_TRAIL=$4 -DOPT_PATH_COMPRESS=$5 ${6:-}"
}
CONFIGS=(
  "naive|$(flags_of 0 0 0 0 0)"
  "+nondet|$(flags_of 1 0 0 0 0)"
  "+scoped|$(flags_of 0 1 0 0 0)"
  "+copy|$(flags_of 0 0 1 0 0)"
  "+epoch|$(flags_of 0 0 0 1 0)"
  "+compress|$(flags_of 0 0 0 0 1)"
  "+epoch+barrier|$(flags_of 0 0 0 1 0 -DOPT_WRITE_BARRIER=1)"
  "+nondet+epoch|$(flags_of 1 0 0 1 0)"
  "default|$(flags_of 1 1 0 0 0)"
  "all|$(flags_of 1 1 1 1 1)"
  "-nondet|$(flags_of 0 1 1 1 1)"
  "-scoped|$(flags_of 1 0 1 1 1)"
  "-copy|$(flags_of 1 1 0 1 1)"
  "-epoch|$(flags_of 1 1 1 0 1)"
  "-compress|$(flags_of 1 1 1 1 0)"
)

# Nondeterministic programs from the old_rice corpus. They aren't aimed
# at one optimization; they show what each does on ordinary search code.
EXTRA=(
  old_rice/benchmarks/cent.curry
  old_rice/benchmarks/queens_perm.curry
  old_rice/benchmarks/half.curry
  old_rice/benchmarks/ndtest.curry
  old_rice/benchmarks/perm.curry
  old_rice/benchmarks/schedule.curry
)

PROGRAM_LIST=()
for f in "$PROGRAMS"/optbench/*.curry; do PROGRAM_LIST+=("$f"); done
for r in "${EXTRA[@]}"; do PROGRAM_LIST+=("$PROGRAMS/$r"); done
SELECTED=()
for f in "${PROGRAM_LIST[@]}"; do
  matches_filter "${f#"$PROGRAMS"/}" && SELECTED+=("$f")
done
if [ "${#SELECTED[@]}" -eq 0 ]; then
  echo "optbench.sh: no programs matched" >&2
  exit 2
fi

mkdir -p "$OUT"
RESULTS="$OUT/results.tsv"
SAMPLES="$OUT/samples.tsv"
: > "$RESULTS"
: > "$SAMPLES"
mismatches=0

now_s() { perl -MTime::HiRes=time -e 'printf "%.6f", time'; }

# build CONFIG FLAGS SRC KIND -> prints the binary's path, or nothing
build() {
  local cname="$1" flags="$2" src="$3" kind="$4"
  local rel="${src#"$PROGRAMS"/}" name; name="$(basename "$src" .curry)"
  local work="$OUT/build/$kind/$cname/${rel%.curry}"
  rm -rf "$work"; mkdir -p "$work"; cp "$src" "$work/"
  local mode=""
  grep -qE '^main[[:space:]]*::.*\bIO\b' "$src" || mode="--interactive"
  ( cd "$work" && timeout "$COMPILE_TIMEOUT" "$RICE" $mode --cflags="$flags" "$name.curry" ) \
    > "$work/build.log" 2>&1
  [ -x "$work/$name" ] && echo "$work/$name"
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
    ( cd "$(dirname "$bin")" && timeout "$RUN_TIMEOUT" "$bin" ) > "$out" 2> "$out.stats"
    code=$?
    if [ "$code" -ne 0 ]; then
      echo "   $rel: exit $code"
      row "$rel" "$cname" status "exit$code"
      continue
    fi
    grep -v '^total memory allocations:' "$out" > "$out.clean"
    ref="$golden"
    [ -f "$ref" ] || ref="$OUT/build/stats/naive/${rel%.curry}/out.clean"
    status=ok
    if [ -f "$ref" ] && ! cmp -s "$ref" "$out.clean"; then
      status=MISMATCH
      mismatches=$((mismatches+1))
      echo "   $rel: OUTPUT MISMATCH against $ref"
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
    ( cd "$(dirname "$bin")" && timeout "$RUN_TIMEOUT" "$bin" ) > /dev/null 2>&1 || return 0
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
