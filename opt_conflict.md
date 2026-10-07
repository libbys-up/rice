# #1 and #5 are unsound together

**Status:** reproduced on the unmodified runtime with a real Curry program;
mechanism confirmed by instrumentation; a fix (a write barrier) is verified
*in a formal model* but **not yet implemented or tested in Rice**.

`OPT_NONDET_TRAIL=1` (#1) and `OPT_EPOCH_TRAIL=1` (#5) are each correct on
their own and wrong together. `epoch.tex`'s argument that #1 already covers
what #5 could skip depends on an invariant that #1 itself breaks.

## Reproducer

`~/curry/papers/unif/proofs/counterexamples/StaleApply.curry`. PAKCS gives
`(False,True)` then `(True,False)`.

```
N="-DOPT_NONDET_TRAIL=0 -DOPT_TAIL_JUMP=0 -DOPT_SCOPED_BACKTRACK=0 -DOPT_COPY_COLLAPSE=0 -DOPT_EPOCH_TRAIL=0"
rice --cflags="$N"                                           StaleApply.curry   # (False,True) (True,False)  ok
rice --cflags="$N -DOPT_NONDET_TRAIL=1"                      StaleApply.curry   # ok
rice --cflags="$N -DOPT_EPOCH_TRAIL=1"                       StaleApply.curry   # ok
rice --cflags="$N -DOPT_NONDET_TRAIL=1 -DOPT_EPOCH_TRAIL=1"  StaleApply.curry   # (False,True) (False,False)  WRONG
```

The `all-on` config in `tests/bench.sh` includes both flags, so it is affected.
The shipped default (#1/#3 on, #5 off) is not.

The program: `x = True ? False` is forced first (creates the choice point).
`o = mk (S (S (S Z))) (pick x)` is an old shared thunk that then reduces
*deterministically* to `Just A`, where `A` is a fresh `apply` node for `f True`
and `f = pick x` depends on the choice.

## Mechanism

Instrumenting `push_node` (add an `fprintf` in the `OPT_EPOCH_TRAIL` branch)
prints exactly one line:

```
[push_node apply nondet=1 epoch=1 cur=1 -> SKIP]
```

1. Forcing `x` runs `choose()`: `current_epoch` 0 -> 1.
2. `o` (epoch 0, old) reduces. Its own reduction touches no choice, so
   `nondet = false`: **#1 does not trail `o`**. It becomes `Just A`; `A` is
   allocated now, epoch 1 (young).
3. `A` is forced. Its function part depends on `x`, so `nondet = true`, but
   `A.epoch (1) < current_epoch (1)` is false: **#5 does not trail `A`**.
   `A` is overwritten in place with `False`.
4. `undo()` restores `x`'s choice frame and nothing else. `nf(expr)` retries.
   `o` was never restored, so it is still `Just A`, and `A` is still `False`.

## Why `epoch.tex`'s argument does not cover this

`epoch.tex` §"undo() restores a whole node" / §"That outermost node is always
older" argues that restoring the outermost trailed node discards everything
built under it, so young nodes never need their own frames. That is true for
references that come *through* that node. It is not true here because `A` has a
**second referrer, `o`**, and `o` was deliberately left out of the trail by #1.
Restoring a node only severs pointers held by nodes that were themselves
restored.

Stated as an invariant: #5's justification requires (not claimed to be equivalent to soundness)

> (I) no cell older than a choice point points at a cell younger than it,
> unless the write that created the pointer was trailed.

This is WAM's binding-order guarantee, transplanted. #1 breaks (I) exactly when
an old deterministic node reduces to something that allocates. The two
justifications need incompatible things:

- #1 assumes: a deterministic result is a persistent *value*; recomputing gives
  the same thing, so it need not be rolled back.
- #5 assumes: nothing old can reach a young cell after backtracking.

The result is a persistent old value holding a reference to a young *mutable*
cell whose later updates were not recorded. #1 alone is fine because the young
cell's nondeterministic update is trailed (nothing is skipped on age). #5 alone
is fine because the old cell's write is trailed.

`epoch.tex`'s microbenchmark and the ten benchmarks contain no node shaped like
`o` (old, shared, reduced only after the choice, allocating a lazily-evaluated
child that depends on the choice).

## Two facts about the current runtime that matter for the fix

1. **`save_copy` has no epoch check.** Generated case-dispatch code emits
   `if(nondet) save_copy(root)` (`ToC.curry:247, 285`). The only epoch-gated
   trail site is `push_node`, reached only from `apply_hnf`
   (`runtime.c:215, 260`). So today #5 can only affect `apply` nodes, which is
   why the reproducer uses a higher-order call.
2. **`OPT_NONDET_TRAIL=0` does not disable #1 in generated code.** The
   `if(nondet)` guard is emitted unconditionally (no `cifdef`). The flag only
   changes `push_node`. So `bench.sh`'s "naive" baseline is not naive for
   compiled functions, and `-DOPT_EPOCH_TRAIL=1` "alone" in generated code
   behaves like #1+#5. `counterexamples/StaleCase.curry` (same directory as
   `StaleApply.curry`) shows this: with an epoch check added to `save_copy` in a
   scratch copy of the runtime (see the README there for the one-line patch), it
   is wrong under `-DOPT_EPOCH_TRAIL=1` even though `OPT_NONDET_TRAIL=0`.

## Options for the compiler

**A. Add a write barrier (keeps both optimizations).** When a node's update
stores a pointer to a cell allocated in a *later* epoch than the node itself,
trail it regardless of `nondet`:

```
must_trail(root, new_children) =
    exists c in new_children . c.epoch > root.epoch
skip the trail iff  (young(root) or !nondet)  and  !must_trail
```

Notes on getting it right:

- Compare `c.epoch > root.epoch` (the two stamps), **not** `c.epoch >= current_epoch`.
  Each choice point bumps the epoch once, so this catches an old-to-young pointer
  relative to *every* choice point on the stack, not only the active one.
- It is only ever an extra reason to trail. It cannot make anything less sound.
- It must be applied at every site that overwrites an existing node's contents:
  the generated `set_X(root, ...)` after the `nondet` gate, `set_forward`,
  `collapse` (both the forward and copy branches; the copy branch's new children
  are the *target's* children), `set_copy` in `apply_hnf`, and
  `set_free_constructor`/`set_copy_free`. `set_copy` already preserves `root`'s
  own epoch (`keep_epoch`), which is what the comparison needs.
- Cost: one epoch compare per child per update to an old node. But it re-trails
  most deterministic updates of old nodes that allocate, so it erodes much of
  what #1 saves on exactly those nodes. Measure before assuming #1+#5 is a win.
- Only needed when both flags are on. With #5 off, #1 alone is sound.

**B. Do not enable #5 together with #1 (simplest).** `epoch.tex` measured zero
effect on every benchmark, and today it only touches apply nodes. Reasonable
choices: make `OPT_EPOCH_TRAIL` require `!OPT_NONDET_TRAIL`, or add
`#if OPT_EPOCH_TRAIL && OPT_NONDET_TRAIL` with an `#error` until (A) exists,
and drop `all-on` from `bench.sh`'s defaults.

**C. Promote instead of trailing.** On an untrailed old-to-young store, raise the
young cell's epoch (and everything reachable from it) to the old cell's. This
avoids re-trailing `o` but is transitive over the young subgraph, which can be
large; I would not start here.

## What is and is not proved

Checked in `~/curry/papers/unif/proofs/Machine.v` (a model of the trail/epoch
logic, not Rice itself):

- `scen_both_stale` reproduces the failure at the model level. `scen_only1_ok`
  and `scen_only5_ok` show each optimization alone is fine. `scen_barrier_ok`
  shows the barrier fixes it. All by computation.
- `ExecStale.v` runs the same program shape on an executable depth-first
  search machine (`Exec.v`) and compares result lists: baseline, #1 alone, #5
  alone, the barrier alone, and #1+#5+barrier all give the correct
  `[(True,False); (False,True)]`; #1+#5 without the barrier gives
  `[(True,False); (False,False)]`, the same wrong answer Rice prints.
- `should_trail_conj` proves #1 and #5 are independent filters (neither
  subsumes the other) when the barrier is off.
- `escape_free` states invariant (I); `do_mutate_escape_free` proves that with the
  barrier on, every mutation preserves it, whatever #1 and #5 decide.

**Not proved / not tested:**

- That invariant (I) plus #1 plus #5 implies the machine computes the same
  solutions as the baseline. That needs the executable machine, still to be built.
- That allocation preserves (I) (true by inspection, since a fresh cell carries the
  current epoch, but needs a stamps-bounded-by-epoch side invariant).
- Anything about Rice's actual implementation of the barrier. Please treat (A)
  as a design to test, not a proven patch.
- Other pairs: a differential fuzzer over the executable machine
  (`ExecBench.v`; random shared-thunk programs, every goal pair) ran all 128
  subsets of {#1..#5, path compression} x {barrier off/on}. Only #1+#5 without
  the barrier disagreed with baseline; no #4 or path-compression interaction
  turned up. Caveat: #2 and #3 are not exercised by the machine, and it is
  unchecked whether path compression fires in the generated programs, so this
  is weak evidence for those three. It is testing, not proof.

## Suggested regression tests

- Add `StaleApply.curry` to `tests/programs/regressions/` with the PAKCS output as
  its golden file, and run it under `all-on`.
- A differential test: random small programs, `naive` vs `all-on` output compared
  against PAKCS/KiCS2. The bug needs an old shared thunk forced after a choice, so
  generate programs with shared `let`-bound thunks and `?`.

## Environment note

While reproducing this I rebuilt `runtime/*.o` in `~/curry/rice/runtime` and
Prelude objects in the shared kics2 cache under several flag sets. The `.flags`
files should trigger recompiles, but `tests/run.sh` (which cleans the cache) will
reset everything. The instrumented and patched runtimes lived only in scratch
copies, not in this tree.
