# Rice's test bench

Curry programs Rice compiles and runs, checked against golden (expected)
output where one exists. Meant to be run before committing, to catch
regressions — not a property-based/unit-test framework (`test/` at the repo
root, unrelated to this directory, is where the C-level `runtime_smoke.c`
lives instead).

## Running it

```
tests/run.sh                 # fast subset: everything not marked SLOW
tests/run.sh --slow          # also run the SLOW (large-input) benchmarks
tests/run.sh regressions     # only paths containing "regressions"
tests/run.sh fib tak         # only paths containing "fib" or "tak"
tests/run.sh -v ...          # print each test's actual output as it runs
tests/run.sh --record ...    # save actual output as the golden, for any
                              # test that passes but doesn't have one yet
```

Exit code is nonzero iff something in the run actually FAILed (compile
error, crash, timeout, or output mismatch against an existing golden).
`XFAIL`/`SLOW`-skipped/no-golden-yet-PASS never affect it, so it's safe to
wire into a pre-commit hook or CI step as-is.

By default, every run starts by wiping Rice's own Prelude optimize-cache
(both `$RICEHOME/.curry` and, if `$KICS2HOME` or `kics2` on `$PATH`
resolves, the kics2 lib's own `rice-1.0.0` cache) — `Rice.Build.Cache`'s
mtime-based staleness has no reason to track `replace/*.curry` as a
dependency of the cached, optimized Prelude, so an edit there needs this
wipe to actually take effect the way a `cypm install` rebuild of `rice`
itself does. Pass `--no-clean` to skip it for faster iterative reruns —
only safe if `replace/*.curry` and `runtime/*.c`/`*.h` haven't changed
since the last clean run.

Each test runs in its own scratch directory under `tests/.run/` (gitignored)
— `.curry` cache and the compiled binary land there, not in
`tests/programs/`, which stays source-only.

## Layout

```
tests/
  run.sh            the correctness test bench
  bench.sh          the performance benchmark bench (own section below)
  lib.sh            small helpers shared by run.sh and bench.sh
  manifest.txt      per-test overrides: SKIP / XFAIL / SLOW / XSLOW, with a reason
  programs/
    old_rice/
      benchmarks/   old_rice's own ~/curry/old_rice/benchmarks/*.curry, verbatim
      suite/        old_rice's own test.zip, verbatim (minus bfNondet.curry,
                     which isn't valid Curry -- design notes/pseudocode, not
                     a program -- and isn't copied in at all)
    regressions/    programs written during this project's own debugging
                     sessions, to guard against the exact bugs they found
    external/       hand-written programs covering language features not
                     well exercised elsewhere, informed by kics2's/pakcs's
                     own test suites (see "On the external/ programs" below)
  .run/             gitignored scratch space run.sh uses; safe to delete
  .bench/           gitignored scratch space bench.sh uses; safe to delete
```

Each `<name>.curry` may have a sibling `<name>.expected` — the golden,
exact-match stdout (with the `total memory allocations: N` trailer stripped
before comparing, since that reflects allocator/optimizer behavior, not
correctness, and can legitimately drift on a good change). No `<name>.expected`
yet just means "hasn't been reviewed and recorded" — `run.sh` still requires
the program to compile, run, and exit cleanly within its timeout, just
without checking the actual output.

## `manifest.txt`

Four statuses, one line per exception:

- `SKIP` — never run at all (e.g. `old_rice/suite/boxes.curry` and
  `deadCode.curry` have no `main`; they're meant for inspecting codegen or
  optimizer output directly, not compiling to an executable).
- `XFAIL` — expected to fail to compile, for a documented, pre-existing
  reason unrelated to Rice (e.g. `queens.curry`'s `import Integer`/`import
  List` — modules that don't exist in modern Curry). If one of these starts
  *succeeding*, `run.sh` reports it as `XPASS` rather than silently passing
  — worth noticing (either Rice or the frontend improved), not something to
  leave stale in the manifest.
- `SLOW` — compiles and runs *correctly*, just not fast enough for a
  before-every-commit pass (old_rice's own benchmarks are deliberately
  large — see `STATUS.md`'s Phase 1 verification pass for why: no
  trampoline or backtracking optimizations beyond the toggle
  infrastructure and #1/#3 exist yet, Phase 2). Skipped by default, run
  with a longer timeout under `--slow`.
- `XSLOW` — a large-input benchmark *expected* to crash or time out once
  actually run under `--slow` (not just slow to complete) — same "no
  trampoline yet" cause as `SLOW`, just past the point of actually
  finishing. Skipped by default like `SLOW`; under `--slow`, a crash/
  timeout doesn't count as a failure (and, like `XFAIL`, an unexpected
  clean run is reported `XPASS` rather than silently passing).

Anything not listed uses `run.sh`'s default timeouts and either matches its
own `.expected` or just needs to exit 0 without timing out.

## `bench.sh` — performance, not correctness

`tests/run.sh` only ever checks *that* a program produces the right
output; `tests/bench.sh` measures *how fast*. Separate script, not a flag
on `run.sh`, since a benchmark run is much longer and shouldn't gate every
commit:

```
tests/bench.sh                          # default OPT_* combos, all SLOW-tagged programs, 3 runs each
tests/bench.sh tak schedule             # only paths containing "tak" or "schedule"
tests/bench.sh --runs=1                 # quick pass -- one sample, noisier wall-clock
tests/bench.sh --csv=/tmp/results.csv   # also write raw (program,config) rows as CSV
tests/bench.sh --configs="a=;b=-DOPT_EPOCH_TRAIL=1"  # replace the default combo set entirely
```

Benches every `SLOW`-tagged program (the only ones both compute-heavy
enough for wall-clock time to be meaningful and confirmed to actually
finish) under a handful of `backtracking-optimizations.md` `OPT_*` combos
by default: a fully-disabled floor (`naive`), the shipped defaults, each
of `#4`/`#5` added on top individually, and both together (`all-on`) --
see the script's own header comment for the full flag list and why a full
2^4 factorial isn't run instead. Reports, per program: minimum wall-clock
time over `--runs` repetitions (robust against one-off scheduler noise --
default 3; raise it for a noisier machine, or use `--runs=1` for a fast
smoke pass), and total allocation count, which is exact and config-
deterministic (read from `nf_all`'s own trailer line) and so only needs
one sample regardless of `--runs`. Results land in `tests/.bench/`
(gitignored, same as `run.sh`'s `.run/`) and aren't committed anywhere as
a golden — a benchmark number is a snapshot of one machine on one day, not
something to regress against the way `run.sh`'s `.expected` files are;
see `STATUS.md`'s dated write-ups for point-in-time findings instead.

`tests/lib.sh` holds the small amount of logic `run.sh` and `bench.sh`
both need (`$RICEHOME`/`rice` resolution, manifest lookup, substring
filtering) — sourced by both rather than duplicated.

## On the `external/` programs

kics2's own test suite (`$KICS2HOME/testsuite/`) is almost entirely built on
`Test.Prop` (CurryCheck's property-testing module — `-=-`, `failing`,
`always`, ...), which Rice doesn't implement and which isn't the
compile-and-check-stdout model this bench uses; importing those files
verbatim would just be a wall of guaranteed compile failures, not useful
coverage. `external/` instead hand-adapts a handful of the *ideas* those
files test (case expressions with guards, higher-order functions, list
comprehensions, functional-pattern-style narrowing, ADT pattern matching)
into ordinary `main`-based programs, credited to the kics2 file that
inspired them in a comment at the top. Add more here as gaps get noticed,
rather than trying to import entire upstream suites wholesale.
