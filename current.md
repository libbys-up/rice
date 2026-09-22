# Current state

## Scoped retry (backtracking-optimizations.md #3, generalized): two defects found and fixed

`SCOPED_CUTOFF()`/`SCOPED_RETRY(...)` in every generated `_hnf` was giving
silently wrong output (`cent`, `debug_repros/cent_tiny.curry`, and a new
lost-solution case, `debug_repros/nested.curry`). Full write-up with heap and
trail graphs: `src/scoped-retry-failures.tex` (+ `.pdf`). The earlier
diagnosis in this file ("scope conflation") was directionally right but the
precise causes are two independent defects, both violating "the trail has a
frame for every cell overwritten since the choice point":

1. **`undo(cutoff)` popped a frame outside its scope.** It is a
   `do { pop } while(...)`, so with `size(bt_stack) == cutoff` (empty scope,
   e.g. a callee reached through `TAIL_DISPATCH`/`collapse` after its logical
   parent pushed a frame) it still popped and restored an ancestor's frame.
   Fix: `runtime/runtime.c` `undo` returns false if `size <= cutoff`.
   (Also protects `lazy_unify_step`'s original hand-written use.)
2. **A failed retry in an `IExempt` branch dropped `root`'s own frame.**
   `showConsBranch` emits `if(nondet) save_copy(root)` first; the body then
   did `SCOPED_RETRY; fail(root)`. A failed retry pops that just-pushed
   frame, so `fail(root)` was an unlogged write (and reset `root`'s `nondet`
   bit). Fix: new `SCOPED_RESAVE(nondet, root)` macro (`runtime/runtime.h`,
   no-op when `OPT_SCOPED_BACKTRACK=0`), emitted by `showStmt ctx n IExempt`
   in `src/Rice/Codegen/C/ToC.curry` between `SCOPED_RETRY` and `fail`. The
   `FAIL_TAG` path was already ordered correctly (retry, then save, then fail).

`OPT_SCOPED_BACKTRACK` stays default **1**.

### Verified (real toolchain, after rebuilding rice)
- `nested`: `FAIL, 2` (was `FAIL, FAIL`). `cent_tiny`: `3, 3, 0, FAIL` (was a
  raw `eval(...)`). `cent`: real solutions == `cent.expected` (528).
- Full suite `tests/run.sh --slow`: 34 pass, 9 xfail, 1 fail. The one failure
  is `cent` and it is only the `SOLUTION: FAIL` golden mismatch below (its
  non-FAIL output equals the golden exactly).
- New regression tests: `tests/programs/regressions/scoped_retry_shared_choice`
  (from `debug_repros/nested.curry`, defect 2) and `scoped_retry_ancestor_frame`
  (from `debug_repros/cent_tiny.curry`, defect 1). Both fail on the unpatched
  build (measured earlier) and pass now. Their goldens include the
  `SOLUTION: FAIL` line, so they will need re-recording if that driver quirk
  is ever fixed.

### Not shown / known open
- Not proven sound, only that these two defects were sufficient for these
  failures. Not argued: `ICaseLit` (retry not wired up there), free-variable
  path, or a case where defect 1 would have popped a *choice* frame.
- A retry can never reach a choice made by an ancestor across a
  `collapse`/`TAIL_DISPATCH` edge (below the callee's cutoff). Recovering that
  would need the cutoff inherited across those edges AND redoing the dispatch
  that depended on the choice, not just re-reading the scrutinee.
- `tests/programs/old_rice/benchmarks/cent.expected` has no `SOLUTION: FAIL`
  lines but every build (even scoped retry off) prints them, because
  `nf_all` only skips a solution when `TAG(expr) == FAIL_TAG` and `expr` is a
  forward to a FAIL cell. So `cent` fails the golden diff independent of this
  work. Not investigated further.

## Build gotcha
Rebuild rice with `kcpm install` (KiCS2's own `cypm`, on PATH as `kcpm`).
Plain `cypm install` now uses PAKCS and installs a broken `rice`
(`*** No value found!` on every input). See memory `rice-build-needs-kics2-on-path`.

## Earlier work this stretch (all completed, verified)
`--force-recompile`, `--force-recompile-module=NAME`, `--compiler-time`,
`-h`/`--help`, Prelude `.c`/`.h` staleness check, `.o` caching, `.rimports`
cache, `--stack-size`, the pairwise benchmark sweep (`tests/bench.sh`), the
flexible-vs-rigid pattern matching note in `STYLE_GUIDE.md`, and the
`nf`/`ground_nf` `FORWARD_TAG`-chasing fix in `runtime.c`.
