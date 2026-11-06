#!/bin/bash
# Rice against KiCS2: time and peak memory of every benchmark program,
# compiled by each with its default settings.
#
# Programs: the same sets as tests/optbench.sh (old_rice benchmarks, KiCS2's
# benchmark suite, the PAKCS examples, and rice's optimization benchmarks),
# each program that has a golden, with its bigger copy from
# programs/scaled/<set>/ where there is one.
#
# Each program is built once by each compiler, then timed in rounds: each
# round runs rice's build and KiCS2's once, so load on the machine spreads
# over both. The report has the minimum over rounds. A run is killed after
# --timeout seconds, or once it uses more than --max-mem MB (KiCS2's
# executables are also built with a GHC heap limit a little below it).
# The output of both is checked against the golden; KiCS2 prints a value
# per line, where rice's --interactive prints "SOLUTION: value".
#
# Usage:
#   tests/compare-kics2.sh [options] [name-substring ...]
#
# Options:
#   --runs=N        timing rounds (default 3)
#   --timeout=SEC   per-run timeout (default 120)
#   --max-mem=MB    per-run memory limit (default 6144)
#   --kics2=PATH    the kics2 executable (default: kics2 on $PATH, or
#                   ~/opt/kics2/bin/kics2)
#   --sets=LIST     comma-separated program sets (old_rice, kics2, pakcs,
#                   optbench; default all)
#
# Results go in tests/.compare/: results.tsv (one row per program) and
# report.md (a table). Don't run this alongside other memory-heavy jobs:
# some KiCS2 runs use gigabytes.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRAMS="$HERE/programs"
OUT="$HERE/.compare"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
resolve_ricehome
resolve_rice

RUNS=3
RUN_TIMEOUT=120
MAX_MEM_MB=6144
COMPILE_TIMEOUT=900
KICS2="$(command -v kics2 || echo "$HOME/opt/kics2/bin/kics2")"
ONLY_SETS=""
FILTERS=()
for arg in "$@"; do
  case "$arg" in
    --runs=*)    RUNS="${arg#--runs=}" ;;
    --timeout=*) RUN_TIMEOUT="${arg#--timeout=}" ;;
    --max-mem=*) MAX_MEM_MB="${arg#--max-mem=}" ;;
    --kics2=*)   KICS2="${arg#--kics2=}" ;;
    --sets=*)    ONLY_SETS="${arg#--sets=}" ;;
    -h|--help)   sed -n '2,35p' "$0"; exit 0 ;;
    *)           FILTERS+=("$arg") ;;
  esac
done
GHC_HEAP_MB=$((MAX_MEM_MB - 512))

SETS=(
  "old_rice|old_rice/benchmarks"
  "kics2|kics2_bench"
  "pakcs|pakcs_examples"
  "optbench|optbench"
)

matches() {
  [ ${#FILTERS[@]} -eq 0 ] && return 0
  local f
  for f in "${FILTERS[@]}"; do
    case "$1" in *"$f"*) return 0 ;; esac
  done
  return 1
}

SELECTED=()
for entry in "${SETS[@]}"; do
  sname="${entry%%|*}"; sdir="${entry#*|}"
  if [ -n "$ONLY_SETS" ] && ! echo ",$ONLY_SETS," | grep -qF ",$sname,"; then
    continue
  fi
  for f in "$PROGRAMS/$sdir"/*.curry; do
    big="$PROGRAMS/scaled/$sname/$(basename "$f")"
    [ -f "$big" ] && f="$big"
    [ -f "${f%.curry}.expected" ] || continue
    matches "${f#"$PROGRAMS"/}" && SELECTED+=("$f")
  done
done
if [ ${#SELECTED[@]} -eq 0 ]; then
  echo "compare-kics2.sh: no programs matched" >&2
  exit 2
fi

now_s() { perl -MTime::HiRes=time -e 'printf "%.6f", time'; }

# run_capped BIN OUT TIMEFILE: run BIN in its own directory under
# /usr/bin/time (for peak memory), killing it after RUN_TIMEOUT seconds or
# once it passes MAX_MEM_MB. Returns the exit code, 124 on a timeout, 125
# on running out of memory.
run_capped() {
  local bin="$1" out="$2" tfile="$3" pid wpid code flag
  flag="$(dirname "$bin")/.killed"
  rm -f "$flag"
  ( cd "$(dirname "$bin")" && exec /usr/bin/time $TIME_RUSAGE_FLAG -o "$tfile" "$bin" ) \
    > "$out" 2>&1 &
  pid=$!
  (
    limit=$((MAX_MEM_MB * 1024)); start=$(date +%s)
    while kill -0 "$pid" 2> /dev/null; do
      for p in $(pgrep -P "$pid"); do
        rss="$(ps -o rss= -p "$p" 2> /dev/null | tr -d ' ')"
        if [ -n "$rss" ] && [ "$rss" -gt "$limit" ]; then
          echo memout > "$flag"; kill -9 "$p" "$pid" 2> /dev/null; exit 0
        fi
      done
      if [ $(( $(date +%s) - start )) -ge "$RUN_TIMEOUT" ]; then
        echo timeout > "$flag"; pkill -9 -P "$pid" 2> /dev/null; kill -9 "$pid" 2> /dev/null
        exit 0
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

# Rice's and KiCS2's output, normalized for comparing with the golden.
# The two print terms differently (rice `S(S(O))` and `(a, b)`, KiCS2
# `(S (S O))` and `(a,b)`), and a nondeterministic program's answers can
# come in a different order (rice evaluates arguments in a different
# order). So the check is on the multiset of answers, with spaces,
# parentheses and commas dropped: `S(S(O))` and `(S (S O))` both become
# `SSO`. That still catches a wrong number of answers, or a wrong value.
# Rice's "SOLUTION: " prefix and "No solutions found" go, as do blank
# lines.
normalize() {
  sed -e 's/^SOLUTION: //' -e '/^No solutions found$/d' -e '/^$/d' \
      -e '/^ld: warning/d' "$1" | tr -d ' (),' | sort
}

build_rice() {
  local src="$1" dir="$2" name; name="$(basename "$src" .curry)"
  mkdir -p "$dir"
  cp "$src" "$dir/"
  local mode=""
  grep -qE '^main[[:space:]]*::.*\bIO\b' "$src" || mode="--interactive"
  grep -q 'rice-mode: interactive' "$src" && mode="--interactive"
  ( cd "$dir" && timeout "$COMPILE_TIMEOUT" "$RICE" $mode "$name.curry" ) > "$dir/build.log" 2>&1
  [ -x "$dir/$name" ]
}

build_kics2() {
  local src="$1" dir="$2" name; name="$(basename "$src" .curry)"
  mkdir -p "$dir"
  cp "$src" "$dir/"
  ( cd "$dir" && timeout "$COMPILE_TIMEOUT" "$KICS2" :set rts -M${GHC_HEAP_MB}m \
      :load "$name" :save :quit ) > "$dir/build.log" 2>&1
  [ -x "$dir/$name" ]
}

mkdir -p "$OUT"
rm -rf "$OUT/build"
RESULTS="$OUT/results.tsv"
printf 'program\trice_s\tkics2_s\trice_mb\tkics2_mb\trice_ok\tkics2_ok\n' > "$RESULTS"
echo "compare-kics2: RICE=$RICE, KICS2=$KICS2, ${#SELECTED[@]} programs, $RUNS rounds"

for src in "${SELECTED[@]}"; do
  rel="${src#"$PROGRAMS"/}"
  base="$OUT/build/${rel%.curry}"
  name="$(basename "$src" .curry)"
  golden="$(normalize "${src%.curry}.expected")"
  rok=build; kok=build
  build_rice "$src" "$base/rice" && rok=""
  build_kics2 "$src" "$base/kics2" && kok=""
  rbest=""; kbest=""; rmem=""; kmem=""
  for r in $(seq 1 "$RUNS"); do
    for who in rice kics2; do
      [ "$who" = rice ] && [ -n "$rok" ] && continue
      [ "$who" = kics2 ] && [ -n "$kok" ] && continue
      bin="$base/$who/$name"
      t0="$(now_s)"
      run_capped "$bin" "$base/$who/out" "$base/$who/time"; code=$?
      t1="$(now_s)"
      secs="$(echo "$t0 $t1" | awk '{printf "%.3f", $2 - $1}')"
      mb="$(peak_rss_mb "$base/$who/time")"
      status=""
      if [ $code -eq 124 ]; then status=timeout
      elif [ $code -eq 125 ]; then status=memout
      elif [ "$(normalize "$base/$who/out")" != "$golden" ]; then status=wrong
      fi
      if [ "$who" = rice ]; then
        [ -n "$status" ] && { rok=$status; continue; }
        rbest="$(echo "$secs ${rbest:-999999}" | awk '{print ($1 < $2) ? $1 : $2}')"
        rmem="$mb"
      else
        [ -n "$status" ] && { kok=$status; continue; }
        kbest="$(echo "$secs ${kbest:-999999}" | awk '{print ($1 < $2) ? $1 : $2}')"
        kmem="$mb"
      fi
    done
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "${rbest:--}" "${kbest:--}" \
    "${rmem:--}" "${kmem:--}" "${rok:-ok}" "${kok:-ok}" >> "$RESULTS"
  printf '  %-40s rice %8ss %6sMB %-7s  kics2 %8ss %6sMB %s\n' "$rel" "${rbest:--}" \
    "${rmem:--}" "${rok:-ok}" "${kbest:--}" "${kmem:--}" "${kok:-ok}"
done

# The report: one row per program, with KiCS2's time over rice's (above 1
# means rice is faster).
{
  echo "| program | rice (s) | KiCS2 (s) | KiCS2 / rice | rice MB | KiCS2 MB |"
  echo "|---|---:|---:|---:|---:|---:|"
  tail -n +2 "$RESULTS" | while IFS=$'\t' read -r p rs ks rm km ro ko; do
    ratio="-"
    if [ "$ro" = ok ] && [ "$ko" = ok ]; then
      ratio="$(echo "$rs $ks" | awk '{ if ($1 > 0) printf "%.2f", $2 / $1; else print "-" }')"
    fi
    [ "$ro" != ok ] && rs="$ro"
    [ "$ko" != ok ] && ks="$ko"
    echo "| $p | $rs | $ks | $ratio | $rm | $km |"
  done
} > "$OUT/report.md"
echo "Report: $OUT/report.md"
