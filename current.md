# Current state

## Status: this investigation is done. Suite is clean. Four commits made.

`tests/run.sh --slow`: **37 pass, 9 xfail, 0 fail, 4 skip.** (Was 34/9/1
before either fix below; the one failure, `cent`, is gone.) Nothing is
pushed. On branch `phase1-codegen-and-runtime`, commits (newest first):
`cf9b51f` (regression goldens for the nf/ground_nf fix), `59658ef` (the
nf/ground_nf fix), `3d3feee` (the scoped-retry writeup + this file),
`81c26fa` (scoped-retry regression tests + repros), `c073eff` (the two
scoped-retry fixes).

You (the user) are separately working on a soundness proof for scoped
retry. Everything below is what got found and fixed while chasing why
`tests/run.sh` wouldn't go fully green; none of it is the proof itself.

## Fix 1: two soundness defects in scoped retry (`backtracking-optimizations.md` #3, generalized)

`SCOPED_CUTOFF()`/`SCOPED_RETRY(...)` in every generated `_hnf` was giving
silently wrong output (`cent`, `debug_repros/cent_tiny.curry`, and a
lost-solution case, `debug_repros/nested.curry`). Full write-up with heap
and trail graphs: `src/scoped-retry-failures.tex` (+ `.pdf`). Two
independent defects, both violating "the trail has a frame for every cell
overwritten since the choice point":

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

**Not proven sound** -- only that these two defects were sufficient to
explain every failure found. Not argued: `ICaseLit` (retry not wired up
there), the free-variable path, or a case where defect 1's stray pop would
land on a *choice* frame instead of an ordinary one. Also: a retry can
never reach a choice made by an ancestor across a `collapse`/`TAIL_DISPATCH`
edge (below the callee's cutoff) -- scoped retry stays strictly local by
construction; recovering that would need the cutoff inherited across those
edges AND redoing the dispatch that depended on the choice, not just
re-reading the scrutinee.

## Fix 2: `nf`/`ground_nf` losing a failure discovered mid-`FORWARD_TAG`-chase

Independent of fix 1 -- reproduces with `OPT_SCOPED_BACKTRACK=0` too. This
is what was actually behind `cent.expected`'s `SOLUTION: FAIL` mismatch,
which fix 1 alone didn't touch (and which "Earlier work this stretch"
below's *other*, earlier `nf`/`ground_nf` fix -- about walking the
`FORWARD_TAG` chain to find `settled` at all -- didn't touch either; this
is a second, later bug in the same two functions).

Both functions chase a `FORWARD_TAG` chain into a local `settled`, calling
`HNF_SETTLE(settled)` along the way. That hands `settled` itself to
arbitrary generated code as its own `root` argument, which can call
`fail(root)` on it directly -- an incomplete `case`, reached right where a
collapse point's forward chain bottoms out. Neither function checked
whether `settled` itself came out `FAIL_TAG` after the chase (only ever
checked its *children*, in the loop just below) -- `FAIL`'s symbol has
`arity = 0`/`payload = PAYLOAD_NONE`, so it slid past every existing check
and the function returned without ever mutating `expr`. `expr` was left
looking like an ordinary forward chain: `nf_all`'s own
`TAG(expr) != FAIL_TAG` check doesn't chase `FORWARD_TAG`, so it read that
as a real solution, and `print_final` -- which *does* chase `FORWARD_TAG`
-- printed the word "FAIL" as if it were the answer.

Fix: `if(TAG(settled) == FAIL_TAG) fail_nf(settled, expr);` right after
each forward-chase loop, in both `nf` and `ground_nf`. Must be `fail_nf`
(saves a copy of `expr` before overwriting), not a bare `fail(expr)` -- a
first attempt used the bare version and regressed `nested` from `FAIL, 2`
to `No solutions found`, since `expr` had no trail record and `undo()`
could never restore it for the next attempt.

## Verified (real toolchain, after rebuilding rice with both fixes)
- `nested` prints exactly `SOLUTION: 2` (no `FAIL` line at all).
- `cent_tiny` prints exactly `3, 3, 0` (no `FAIL` line).
- `cent`'s output is a byte-for-byte match against `cent.expected`.
- `tests/run.sh --slow`: 37 pass, 9 xfail, 0 fail, 4 skip.
- Regression tests added/updated:
  `tests/programs/regressions/scoped_retry{,_shared_choice,_ancestor_frame}`.
  All three originally had a `SOLUTION: FAIL` line baked into their
  `.expected`; re-recorded once fix 2 landed (that line was always bogus,
  a symptom of fix 2's bug, not a legitimate expected output -- see
  `scoped_retry.curry`'s own updated doc comment).

## Build gotcha
Rebuild rice with `kcpm install` (KiCS2's own `cypm`, aliased on PATH as
`kcpm` -- note: it's a shell *alias*, so it won't expand inside a `bash -c`
subshell or other non-interactive wrapper; use the literal
`cypm --define currybin=/Users/libbys/opt/kics2/bin/kics2 install` there).
Plain `cypm install` now uses PAKCS and installs a broken `rice`
(`*** No value found!` on every input). See memory
`rice-build-needs-kics2-on-path`.

## Earlier work this stretch (all completed, verified, predates this file)
`--force-recompile`, `--force-recompile-module=NAME`, `--compiler-time`,
`-h`/`--help`, Prelude `.c`/`.h` staleness check, `.o` caching, `.rimports`
cache, `--stack-size`, the pairwise benchmark sweep (`tests/bench.sh`), the
flexible-vs-rigid pattern matching note in `STYLE_GUIDE.md`, and an earlier,
different `nf`/`ground_nf` fix in `runtime.c` (multi-argument tail-recursive/
`collapse`-based calls not chasing `FORWARD_TAG` far enough to find
`settled` in the first place -- distinct from fix 2 above, which is about
what happens once `settled` is found and turns out to be `FAIL`).
