#!/bin/bash
# Rice's performance benchmark bench: builds and times a curated set of
# compute-heavy Curry programs under several OPT_* flag combinations
# (docs/history/backtracking-optimizations.md), to measure the actual wall-clock
# and allocation-count effect of each toggle. tests/run.sh only checks
# correctness; this checks speed -- the two are deliberately separate
# scripts since a benchmark run can take much longer than a correctness
# pass and shouldn't gate every commit the way run.sh does.
#
# Usage:
#   tests/bench.sh [options] [name-substring ...]
#
# Options:
#   --configs=NAME=FLAGS[;NAME=FLAGS...]
#                  replace the default OPT_* combos entirely (semicolon-
#                  separated; FLAGS is whatever --cflags takes, e.g.
#                  "-DOPT_EPOCH_TRAIL=1 -DOPT_COPY_COLLAPSE=1"; an empty
#                  FLAGS means "rice's own compiled-in defaults")
#   --runs=N       wall-clock repetitions per (program,config); the
#                  minimum real time is kept, to be robust against one-off
#                  scheduler noise (default 3). Allocation counts aren't
#                  affected by --runs: they're read straight from the
#                  first successful run's own "total memory allocations:"
#                  line (runtime.c's nf_all, with RICE_ALLOC_STATS set), which is exact and
#                  deterministic for a given config, not something
#                  repeated sampling improves.
#   --timeout=SEC  per-run timeout (default 200 -- these are meant to be
#                  the SLOW-tagged large-input benchmarks; see manifest.txt)
#   --csv=FILE     also write one row per (program,config) result as CSV
#   --clean        wipe the Prelude optimize-cache first, the same one-time
#                  cost tests/run.sh's default (non---no-clean) path pays --
#                  only needed if replace/*.curry or runtime/*.c/*.h changed
#                  since the last clean build; off by default here since a
#                  benchmark run is long enough already and cflags alone
#                  (what actually varies between configs) never touches
#                  that cache -- see run.sh's own comment on why the cache
#                  exists at all.
#   -v, --verbose  print each run's timing as it happens, not just the
#                  final table
#
# name-substring, if given, filters to programs whose relative path
# contains any of the given substrings (run.sh's own convention).
#
# Programs benched: every tests/manifest.txt entry marked SLOW -- compute-
# heavy enough for wall-clock time to mean something, and confirmed to
# actually finish (not XFAIL/XSLOW/SKIP, none of which produce a valid
# measurement) -- regardless of filters, which only narrow within that set,
# not add outside it. Widen with `--include-fast` to also bench everything
# else (small/instant programs), useful only for the allocation-count
# column, not wall-clock, whose noise floor swamps anything that fast.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRAMS="$HERE/programs"
MANIFEST="$HERE/manifest.txt"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
resolve_ricehome
resolve_rice
SCRATCH="$HERE/.bench"
COMPILE_TIMEOUT=60
RUN_TIMEOUT=200
RUNS=3
CLEAN=0
VERBOSE=0
CSV=""
INCLUDE_FAST=0
CONFIGS_OVERRIDE=""
FILTERS=()

for arg in "$@"; do
  case "$arg" in
    --configs=*)     CONFIGS_OVERRIDE="${arg#--configs=}" ;;
    --runs=*)        RUNS="${arg#--runs=}" ;;
    --timeout=*)     RUN_TIMEOUT="${arg#--timeout=}" ;;
    --csv=*)         CSV="${arg#--csv=}" ;;
    --clean)         CLEAN=1 ;;
    --include-fast)  INCLUDE_FAST=1 ;;
    -v|--verbose)    VERBOSE=1 ;;
    -h|--help)       sed -n '2,45p' "$0"; exit 0 ;;
    *)               FILTERS+=("$arg") ;;
  esac
done

if [ ! -x "$RICE" ]; then
  echo "bench.sh: can't find a 'rice' executable (looked for \$PATH and ~/.cpm/bin/rice)" >&2
  exit 2
fi

if [ "$CLEAN" -eq 1 ]; then
  echo "Cleaning rice's caches (lib/, replace/, runtime objects)..."
  clean_rice_caches
fi

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
RESULTS="$SCRATCH/results.tsv"
: > "$RESULTS"

# --- the OPT_* combos to compare. A true naive floor (all four off),
# then one config per optimization -- naive plus *just that one* flag on
# -- isolating each optimization's own individual contribution against
# the same floor. (#2, eager tail dispatch, has no switch any more: on
# the evaluation machine every tail call is a musttail jump.)
# `default` (today's shipped defaults: #1/#3 on, rest off) and `all-on`
# (everything, path compression included; #1+#5 turns on the write
# barrier) stay as bonus reference points, not part of the pairwise isolation
# itself. Not a full 2^4 factorial -- docs/history/backtracking-optimizations.md's own
# "Orthogonality" notes already argue the five don't interact in ways a
# factorial sweep would need to expose, and 16 configs would multiply
# this script's already-long runtime for little extra signal.
CONFIG_NAMES=()
CONFIG_FLAGS=()
if [ -n "$CONFIGS_OVERRIDE" ]; then
  IFS=';' read -ra entries <<< "$CONFIGS_OVERRIDE"
  for e in "${entries[@]}"; do
    CONFIG_NAMES+=("${e%%=*}")
    CONFIG_FLAGS+=("${e#*=}")
  done
else
  NAIVE="-DOPT_NONDET_TRAIL=0 -DOPT_SCOPED_BACKTRACK=0 -DOPT_COPY_COLLAPSE=0 -DOPT_EPOCH_TRAIL=0"
  CONFIG_NAMES=(naive +nondet-trail +scoped-backtrack +copy-collapse +epoch-trail default all-on)
  CONFIG_FLAGS=(
    "$NAIVE"
    "$NAIVE -DOPT_NONDET_TRAIL=1"
    "$NAIVE -DOPT_SCOPED_BACKTRACK=1"
    "$NAIVE -DOPT_COPY_COLLAPSE=1"
    "$NAIVE -DOPT_EPOCH_TRAIL=1"
    ""
    "-DOPT_NONDET_TRAIL=1 -DOPT_SCOPED_BACKTRACK=1 -DOPT_COPY_COLLAPSE=1 -DOPT_EPOCH_TRAIL=1 -DOPT_PATH_COMPRESS=1"
  )
fi

# perl's Time::HiRes, not bash's own `time` builtin or `date +%N`: portable
# sub-second wall-clock across bash versions (this needs to keep working
# under macOS's stock bash 3.2, same reasoning as run.sh's own comments)
# and platforms (BSD `date` has no %N at all), and perl ships with the
# base OS rather than needing a brew/ports install the way GNU date would.
now_s() { perl -MTime::HiRes=time -e 'printf "%.6f", time'; }

# bench_one CONFIG_NAME FLAGS SRC
bench_one() {
  local cname="$1" flags="$2" src="$3"
  local rel="${src#"$PROGRAMS"/}"
  local name; name="$(basename "$src" .curry)"
  local work="$SCRATCH/$cname/${rel%.curry}"
  rm -rf "$work"; mkdir -p "$work"
  cp "$src" "$work/"

  local build_log="$work/build.log"
  # Every SLOW-tagged program this script benches is written in the
  # old_rice bare-goal style (main :: Int/[Int]/..., not IO), so this
  # always needs --interactive (nf_all) to run at all under Rice's
  # default "standalone executable" mode (run_io) -- and the allocation
  # count this script parses out of each run's own output (below) is
  # nf_all's "total memory allocations:" line specifically, so a
  # standalone-mode build wouldn't even print it. Same IO-signature
  # detection as run.sh's own, for the same self-maintaining reason.
  local mode_flag=""
  grep -qE '^main[[:space:]]*::.*\bIO\b' "$src" || mode_flag="--interactive"
  if [ -n "$flags" ]; then
    ( cd "$work" && timeout "$COMPILE_TIMEOUT" "$RICE" $mode_flag --cflags="$flags" "$name.curry" ) >"$build_log" 2>&1
  else
    ( cd "$work" && timeout "$COMPILE_TIMEOUT" "$RICE" $mode_flag "$name.curry" ) >"$build_log" 2>&1
  fi
  if [ ! -x "$work/$name" ]; then
    [ "$VERBOSE" -eq 1 ] && echo "  [$cname] $rel: BUILD FAIL (see $build_log)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$cname" "NA" "NA" "buildfail" >> "$RESULTS"
    return
  fi

  local best="" allocs="NA" status="ok"
  local i out_log t0 t1 elapsed code
  for i in $(seq 1 "$RUNS"); do
    out_log="$work/out.$i.log"
    t0="$(now_s)"
    ( cd "$work" && RICE_ALLOC_STATS=1 timeout "$RUN_TIMEOUT" "./$name" ) >"$out_log" 2>&1
    code=$?
    t1="$(now_s)"
    elapsed="$(perl -e "printf '%.3f', $t1 - $t0")"

    if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
      status="timeout"
      [ "$VERBOSE" -eq 1 ] && echo "  [$cname] $rel: run $i TIMEOUT (>${RUN_TIMEOUT}s)"
      continue
    fi
    if [ "$code" -ne 0 ]; then
      status="crash"
      [ "$VERBOSE" -eq 1 ] && echo "  [$cname] $rel: run $i CRASH (exit $code)"
      continue
    fi
    if [ "$allocs" = "NA" ]; then
      allocs="$(grep '^total memory allocations:' "$out_log" | awk '{print $NF}')"
      [ -z "$allocs" ] && allocs="NA"
    fi
    if [ -z "$best" ] || (( $(perl -e "print(($elapsed < $best) ? 1 : 0)") )); then
      best="$elapsed"
    fi
    [ "$VERBOSE" -eq 1 ] && echo "  [$cname] $rel: run $i real ${elapsed}s"
  done

  [ -z "$best" ] && best="NA"
  printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$cname" "$best" "$allocs" "$status" >> "$RESULTS"
}

echo "Benchmarking with RICEHOME=$RICEHOME, RICE=$RICE"
echo "Configs: ${CONFIG_NAMES[*]}"
echo

# --- gather the SLOW-tagged program set (see this script's own header
# comment for why: XFAIL/XSLOW/SKIP entries can't produce a real
# measurement, and non-manifest ("fast") programs are noise-dominated at
# the wall-clock level unless --include-fast opts them in anyway).
PROGRAM_LIST=()
while IFS= read -r -d '' f; do
  rel="${f#"$PROGRAMS"/}"
  matches_filter "$rel" || continue
  status="$(manifest_status "$rel")"
  if [ "$status" = "SLOW" ] || { [ "$INCLUDE_FAST" -eq 1 ] && [ "$status" != "SKIP" ] && [ "$status" != "XFAIL" ] && [ "$status" != "XSLOW" ]; }; then
    PROGRAM_LIST+=("$f")
  fi
done < <(find "$PROGRAMS" -name '*.curry' -print0 | sort -z)

if [ "${#PROGRAM_LIST[@]}" -eq 0 ]; then
  echo "bench.sh: no SLOW-tagged programs matched the given filter(s)" >&2
  exit 2
fi

total=$(( ${#CONFIG_NAMES[@]} * ${#PROGRAM_LIST[@]} ))
done_count=0
for src in "${PROGRAM_LIST[@]}"; do
  rel="${src#"$PROGRAMS"/}"
  for idx in "${!CONFIG_NAMES[@]}"; do
    done_count=$((done_count+1))
    echo "[$done_count/$total] $rel (${CONFIG_NAMES[$idx]})"
    bench_one "${CONFIG_NAMES[$idx]}" "${CONFIG_FLAGS[$idx]}" "$src"
  done
done

if [ -n "$CSV" ]; then
  { echo "program,config,min_seconds,allocations,status"; sed 's/\t/,/g' "$RESULTS"; } > "$CSV"
  echo
  echo "Raw results written to $CSV"
fi

echo
echo "== Wall-clock (min of $RUNS run(s), seconds) =="
{
  printf 'program'; for c in "${CONFIG_NAMES[@]}"; do printf '\t%s' "$c"; done; printf '\n'
  for src in "${PROGRAM_LIST[@]}"; do
    rel="${src#"$PROGRAMS"/}"
    printf '%s' "$rel"
    for c in "${CONFIG_NAMES[@]}"; do
      row="$(awk -F'\t' -v r="$rel" -v c="$c" '$1==r && $2==c {print $3"|"$5}' "$RESULTS")"
      val="${row%%|*}"; st="${row#*|}"
      if [ "$st" = "ok" ] || [ -z "$st" ]; then printf '\t%s' "$val"; else printf '\t%s' "$st"; fi
    done
    printf '\n'
  done
} | column -t -s $'\t'

echo
echo "== Total memory allocations (exact, config-deterministic) =="
{
  printf 'program'; for c in "${CONFIG_NAMES[@]}"; do printf '\t%s' "$c"; done; printf '\n'
  for src in "${PROGRAM_LIST[@]}"; do
    rel="${src#"$PROGRAMS"/}"
    printf '%s' "$rel"
    for c in "${CONFIG_NAMES[@]}"; do
      val="$(awk -F'\t' -v r="$rel" -v c="$c" '$1==r && $2==c {print $4}' "$RESULTS")"
      printf '\t%s' "$val"
    done
    printf '\n'
  done
} | column -t -s $'\t'
