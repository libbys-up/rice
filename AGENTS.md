# Working on rice

A short guide for anyone working on rice, and for AI coding tools: how to
build and test it, the rules that keep you out of trouble, and where things
are documented. The design itself is in `docs/developers-manual.tex`.

## Building

Rice is written in Curry and built with KiCS2 3.5.

```bash
make CYPM=/path/to/kics2/bin/cypm     # front end, rice, standard library
PATH=/path/to/kics2/bin:$PATH cypm install   # rebuild just rice
```

- **Use KiCS2's `cypm`.** `cypm` builds with whichever Curry system it
  belongs to. A PAKCS-built rice compiles but fails on every program
  (`make rice` checks this; a bare `cypm install` doesn't).
- After a rebuild, compile a tiny program and check the output before
  trusting any experiment. Don't send a compile you're checking to
  `/dev/null`.
- After changing code generation, `replace/` or the runtime, clear the
  caches (`tests/run.sh` does unless given `--no-clean`; or
  `rm -rf lib/.curry replace/.curry runtime/obj-*`). The staleness check
  doesn't know about the compiler itself.

## Testing

```bash
tests/run.sh                 # the suite; about 7 minutes from clean caches
tests/run.sh name-substring  # some of it
tests/bootstrap.sh           # rice compiles itself; generated C must match
make -C runtime test         # the runtime's C smoke test
```

- Run `tests/run.sh` before every commit, and `tests/bootstrap.sh` before
  any commit that changes code generation or the runtime.
- Every test's output is checked against its `.expected` golden. Check a new
  golden against KiCS2 or PAKCS (or an independent check) before recording
  it, and say which in the test's header. Never record rice's own output
  just because it's what rice prints.
- Runtime changes get a test run under `-- rice-flags: --cflags=-DGC_STRESS`.
- When a test reproduces a bug, check that it fails without the fix.
  Rice's evaluation order can hide a bug: `nf` evaluates a tuple's last
  field first, and nested cases become separate functions, so a
  counterexample written for another system may never reach the bad state.
  For the write barrier, `-DOPT_ALLOW_UNSOUND=1 -DOPT_WRITE_BARRIER=0`
  builds without it.

## Rules for long or heavy jobs

- **Never run two memory-heavy jobs at once** (a suite, the bootstrap test,
  a benchmark, a KiCS2 run): on a 16 GB machine that has caused a kernel
  panic. Cap a KiCS2 run whose memory you don't know (`:set rts -M8g`).
- **Two `tests/run.sh` at once** only if the second passes `--no-clean`; a
  clean start deletes the caches the first one is using.
- **Never edit a test script while it runs**: bash reads scripts as it goes.
- **Keep the machine awake** for long runs (macOS: `caffeinate -i -w <pid>`).
  The benchmarks take hours (`tests/optbench.sh` about a day with
  `--runs=5`), and a sleep inside a timing ruins it.
- Benchmarks: `tests/optbench.sh` (the backtracking optimizations) and
  `tests/compare-kics2.sh` (rice against KiCS2). Their results so far are in
  `docs/results/`.

## Conventions

`docs/style-guide.md` has them all. The ones most often missed:
- Code comments say what the code does and why. History (bugs fixed,
  approaches dropped, measurements) goes in `docs/history/`, and design in
  the developer's manual.
- In the runtime, changing a node that already exists means: trail it if a
  choice could undo it (`trail_node`), tell the collector (`gc_remember`),
  and keep pointers in `GC_ROOT` across anything that runs the machine.
- The backtracking optimizations have soundness rules (developer's manual,
  "Soundness rules"). Changing the trail, the case loop, `collapse` or
  allocation means keeping them; the regression tests named there check.
- No nondeterminism (`?`, free variables) in rice's own Curry code.

## Where things are

| | |
|---|---|
| `README.md` | installing and using rice |
| `docs/developers-manual.tex` | the design: compiler, runtime, collector, optimizations |
| `docs/style-guide.md` | coding and commenting conventions |
| `docs/status.md` | where the project stands, and what's next |
| `docs/plans/` | plans for work not done yet |
| `docs/results/` | measurements behind the defaults |
| `docs/history/` | finished plans and histories: why things are the way they are |
| `tests/README.md` | the test bench |
| `src/Rice/` | the compiler; `runtime/` the runtime; `lib/` the standard library |
