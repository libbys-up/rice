# Implementing the backtracking optimizations correctly

This is the implementation guide that goes with the Rocq proofs in
`~/curry/papers/unif/proofs`. The full write-up is
`backtracking_report.tex` there; the barrier is covered in detail in
`epoch_barrier.tex`. This file says what Rice has to do for each
optimization to match what was proved, and where the current code
differs.

(The implementation status is at the end of this file.)

The proofs are about a model of
Rice's machine, not about the C code, so every rule below is a
requirement derived from the model plus a reading of the code. Each one
needs a test on Rice itself.

## What is proved

On the model, every subset of #1, #3, #4, #5 computes the same answers as
the unoptimized machine, provided the write barrier below is on whenever
#1 and #5 both are. Each of these also holds with path compression
added (see the end).

- **Without #1** (#3, #4, #5 in any combination): the same answer list
  and completion flag, exactly.
- **With #1**: if both runs finish, they give the same answers in the
  same order, up to renaming of fresh variables. "If the baseline
  finishes, so does #1" is proved for #1 alone, not for its
  combinations.
- **#2** (eager tail dispatch) is not modeled. It only changes the C
  stack.
- **One axiom**: confluence of deterministic graph rewriting (Echahed and
  Janodet 1997, Theorem 1), used by everything that includes #1.

## Restrictions the proofs need

The results apply to programs and runs that satisfy these:

1. **The program is a LOIS system**, as Curry's pattern-matching
   compilation produces: linear constructor patterns, right-hand-side
   variables bound on the left, and definitional trees whose branches
   only inspect positions that extend ones already matched.
2. **Choices are in standard form**: `f x = f1 x ? f2 x`, every
   alternative a rule. ICurry produces this. The model needs it because
   it re-walks from the top after each step; Rice keeps the frame live
   and probably does not, but nothing is proved without it.
3. **Graphs are admissible**: no operation node can reach itself.
   `let xs = True : xs` (a cycle through a constructor) is fine.
   `let x = not x` (a cycle through a call) is outside the theorems. #1's
   proof rests on confluence of deterministic graph rewriting, which only
   holds for admissible graphs.
4. **The run starts fresh**: empty trail and choice-point stack, no
   dangling pointers, and node stamps no later than the current epoch.
   Any start state Rice builds by allocation satisfies these.

## Nondet tracking (needed by #1, and by #4 with #1)

#1 skips the trail entry for a rewrite whose `nondet` is false. That is
only sound if `nondet` really covers everything the rewrite depended on.
The model got this wrong three times; Rice must satisfy all of these.

1. **Every inspected node counts.** OR in the `nondet` flag of every node
   the match reads: every hop of a forward chain, and every intermediate
   node of a nested pattern, not only the final scrutinee. This is still
   unchecked for Rice's multi-field and nested matches.
2. **Flags are sticky.** A node can be rewritten more than once, when its
   right-hand side is another call. A later rewrite of a node whose flag
   is set must also count as nondeterministic. A fresh evaluation of a
   node starts from that node's own flag, not from false.
3. **Evaluating a needed argument keeps the accumulated flag.** When the
   match must first evaluate an argument (`FUNCTION_TAG` in the case
   loop), the flag collected on the way to it still applies.
4. **A choice is always nondeterministic**, including its last
   alternative. Treating the last alternative as deterministic loses
   answers. In `main = (y, x)` with `y = Z ? S Z` and `x = True ? False`,
   the answer `(S Z, True)` disappears: `x`'s `False` survives the retry
   of `y`.
5. **Free-variable bindings are always trailed and flagged.** Rice
   already does this (`save_copy`, `push_choice`, `choose`).

Rice satisfies the first property for its own write in an indirect way.
An outer case's `showConsBranch` has already done
`trail_node(root, nondet_outer)` before a nested case resets `nondet`.
The rule for anything that pops that outer frame is in the #3 section
below.

## #1: Nondet-gated trailing

The rule is already Rice's: `needs_trail` returns false when `nondet` is
false. Nothing else changes, and the walk's decisions never read the
trail.

**Known issue.** `OPT_NONDET_TRAIL=0` does not turn #1 off in generated
code, because the `if(nondet)` gate is emitted unconditionally
(`opt_conflict.md`). For a baseline you can trust in benchmarks and
differential tests, the gate should follow the flag.

## #3: Scoped early backtracking

1. **The fail write must always be trailed.** The #3 proof rests on this.
   A scope with no local alternative left writes `FAIL` into its root, and
   the next pop must undo that write. Under #1,
   `SCOPED_RESAVE(nondet, root)` trails only when the failing case's own
   `nondet` is set. `enterCase` resets that flag for every case,
   including nested ones, so this is wrong:

   ```curry
   f :: Bool -> Bool -> Bool
   f x y = case x of
     True  -> case y of True -> True
     False -> False
   main = let x = True ? False in (x, f x False)   -- PAKCS: (False,False)
   ```

   The inner case fails with `nondet` false. The failed `SCOPED_RETRY`
   pops the outer branch's trail frame, and `SCOPED_RESAVE` does not
   re-trail, so `f x False` stays `FAIL` after `x` flips. The prediction
   is no solution with #1 and #3 on (`counterexamples/ScopedNestedND.curry`;
   predicted by the model, not yet run on Rice).

   **Fix:** make `SCOPED_RESAVE` trail unconditionally
   (`save_snapshot(root)`, setting the flag), or start a nested case's
   `nondet` at the enclosing case's value. Both fix the model; the
   proved form is the unconditional one.

2. **A retry must redo every dispatch that read the flipped choice.**
   This is outside the model, whose retry re-walks from the choice
   point's node.

   ```curry
   main = f (True ? False) False                    -- same f; PAKCS: False
   ```

   The choice is made by `f`'s outer case. The inner case fails, and
   `SCOPED_RETRY` flips the choice and continues the inner case loop.
   That loop re-reads only `y`; the outer dispatch on `x` is never
   redone. The prediction is no solution with #3 on
   (`counterexamples/ScopedStaleDispatch.curry`, not yet run).
   `src/scoped-retry-failures.tex` already notes the problem. The model's
   theorem says nothing about this: it is a question of how Rice resumes,
   which the model does not represent.

3. The scoped retry inside `=:<=` (`lu_k`) is not modeled.

## #4: Copy instead of forward

1. **Copy only a constructor that cannot be undone.** That means not a
   function, choice, or free variable, and `nondet` false. This is Rice's
   `collapse_safe`.
   - #4 alone does not need the `nondet` part.
   - #1+#4 does:

     ```curry
     unjust (Just v) = v
     main = let q = True ? False in (q, unjust (Just q))
     ```

     `unjust`'s rewrite reads only the `Just` cell, so it is
     deterministic. Without the guard it copies `q`'s `True` untrailed,
     and backtracking into `q` leaves the copy stale: `(False, True)`
     instead of `(False, False)`.
2. **The copy write is trailed exactly like the forward it replaces**
   (same `nondet`, same trail decision). Writing it without a trail entry
   breaks agreement in the bench.
3. **The copy keeps the destination's own `nondet` and `epoch`.** Rice's
   `collapse`/`set_copy` already do this.
4. The proof has a dereference-budget hypothesis, but that is an artifact
   of the model. Rice has no such budget.

## #5: Epoch trailing

1. **The rule:** skip the trail entry when `root.epoch >= current_epoch`.
   This is Rice's `needs_trail`.
2. **Epochs:**
   - each choice point increments `current_epoch` once;
   - `undo` restores the epoch saved in the choice point;
   - a retried alternative runs at saved epoch + 1. Rice's `choose` and
     `push_choice` both increment, and `stack.c` saves and restores.
3. **A snapshot keeps the node's own epoch.** `undo`'s whole-node memcpy
   then restores an old node as old. `push_node` does this. A `copy()`
   used as a snapshot must not restamp it as young.
4. **Every trail site must apply the same decision.** `save_copy`, used
   by generated case dispatch, has no epoch check, so today #5 only
   affects `apply` nodes. Adding the check is what makes #5 do anything
   for compiled functions. It is also what makes the barrier necessary
   for those functions, so the two must land together.
5. #5 without #1 needs no barrier and is proved with the barrier off.

## The write barrier (required when #1 and #5 are both on)

### Why

#1 leaves a deterministic rewrite of an old node untrailed. If that
rewrite stores newly allocated nodes, the old node now points at young
nodes. A later nondeterministic update of one of those young nodes is
skipped by #5 (young), and after backtracking the old node still reaches
the stale value.

```curry
mk :: Bool -> (Bool, ())
mk b = (not b, ())

main = let b = True ? False
           p = mk b
       in (b, fst p)          -- expected (True,False), (False,True)
```

- `p` is rewritten deterministically to `(n, ())`, with `n` new. #1 does
  not trail this write.
- `n` is then evaluated using `b`: a nondeterministic write to a young
  node, which #5 does not trail.
- After backtracking, `fst p` still gives `False`, so the second answer
  is `(False, False)`.

Rice reproduces this with `counterexamples/StaleApply.curry`, and
`runtime.h` currently forbids the combination with an `#error`.

### The rule

> When a node is rewritten deterministically (its trail decision used
> `nondet == false`), every node allocated to build its new value gets
> the stamp `min(root.epoch, current_epoch)` instead of `current_epoch`.
> Nondeterministic rewrites and free-variable bindings allocate at
> `current_epoch` as now. Nothing extra is trailed.

The new nodes then count as old as the node they hang from. A later
nondeterministic update of one of them is trailed by #5, and backtracking
restores it. In the example, `n` gets `p`'s stamp, so its update to
`False` is trailed, and `mk` is not re-run on the retry.

Why it works (proved in `Opt15_Stamp.v`): an unflagged node never points
at anything younger than itself. A deterministic rewrite's other
pointers are pattern variables, and those are already no younger than the
root. The property survives undo, because undo restores contents and
flag together and stamps never change after allocation.

### Cost

One stamp read per rewrite, and no walk. The only loss is to #5's savings
on nodes built by deterministic rewrites of old nodes, and those are
exactly the nodes the bug goes through. Lowering a stamp further than
the rule says should be safe, since it can only make #5 trail more, but
the proof covers exactly the rule as stated. Raising a stamp is never
safe. If a site is unclear, lowering is the direction to err in.

Do **not** use the earlier designs in `opt_conflict.md`:
- **Option A (trail the old node):** correct in tests, but it re-trails
  most deterministic rewrites of old nodes, and its proof does not go
  through.
- **Option C (promote the reachable young subgraph):** correct, but
  walks the subgraph. The rule above is option C done at allocation
  time, where the walk is never needed.

### Where it applies

The rule applies at every site that allocates nodes and stores them into
an existing node as part of a rewrite with `nondet` false:

1. **Generated rewrites.** In a case branch, `showConsBranch` does
   `trail_node(root, nondet)`, and the body then builds the right-hand
   side:
   - the `make_*` calls from `setExpr` and `showExpr`;
   - `make_choice`;
   - `make_apply*`;
   - `free_var()` for `let x free`;
   - let-bound `INodeAssign`s;

   and finally calls `set_X(root, ...)`. With `nondet` false, all of
   those allocations take the lowered stamp. `setExpr` never forces
   before writing `root`, so the straight-line allocations of one body
   belong to that one rewrite.
   - A nested case inside the body is a separate dispatch with its own
     trail point. Recompute the stamp there.
   - The uncased path (`uncaseTrail Nothing`: `trail_node(root, false)`)
     is always deterministic, so it always lowers.
2. **`apply_hnf`** (`push_node` with `nondet`, then `set_copy` or partial
   application fill) when the result allocates.
3. **`collapse` / `set_forward` / `set_copy`.** These allocate nothing
   new: the copy's children are the target's, and a forward points at an
   existing node. Nothing to do, but they must keep `root`'s own epoch,
   as they already do.
4. **Fail writes** allocate nothing.

Implementation options:
- **(a) Pass the stamp explicitly.** The code generator emits
  `unsigned _stamp = nondet ? current_epoch : MIN(root.n->epoch, current_epoch);`
  right after each `trail_node` and passes `_stamp` to `make_*` variants
  that stamp with it. ToH's `epochStamp` is the place to change.
- **(b) A global allocation epoch** that `make_*`, `free_var`,
  `make_choice` and `make_forward` read instead of `current_epoch`. It is
  set at each trail point and reset whenever evaluation of another node
  begins and after every choice push. This is more fragile, because
  every `hnf` entry must restore it.

(a) is simpler to get right. Under either option, `MIN` matters: nodes
allocated in a dead branch can carry a stamp above the current epoch, and
a new node must never be stamped later than `current_epoch`.

### Then

Replace the `#error` with a requirement that the barrier is on whenever
#1 and #5 both are. Keep it off when #1 is off: #5 without #1 was proved
with the barrier off. Lowering stamps there should be harmless, since it
only adds trail entries, but that case is not proved.

## Path compression (not in Rice)

The model has one more optimization, path compression. At a match
position whose node is a forward `r -> a`, it follows the forwards from
`a` whose `nondet` flag is false and retargets `r` straight to where they
lead. It is proved sound alone and with every subset of #1, #3, #4, #5
(and the barrier), in the same sense as the table above
(`PathCompress_Combos.v`). If Rice adds it:
- skip only forwards with `nondet` false;
- make the retargeting write go through the ordinary trailing decision
  as a *deterministic* write (`nondet` false): with no trailing
  optimization it is trailed, under #1 it is not, under #5 alone it is
  trailed exactly when `r` is older than the current epoch;
- keep `r`'s own flag and epoch.

Why the trail entry matters when it is pushed: it saves `r`'s one-hop
old target. Undo pops newest first, so `r` goes back to its old target
before (or together with) any hop it skipped, and `r`'s own older
entries (e.g. the thunk it was before collapsing) are restored after
that. Dropping the entry was fine on every test, but the proof without
#1 uses it.

Why it can be skipped under #1: the hops compression skips are
unflagged, and under #1 an unflagged node never has a trail entry, so no
undo ever changes a skipped hop; `r` keeps pointing at the right place.
This is also why the flag check is needed with #1 (tests: 19 wrong
goals without it) and not alone.
## Tests to add

Regression programs, each with PAKCS's output as the golden file, run
under every flag combination:

| Program | What it checks |
|---|---|
| `counterexamples/StaleApply.curry` | #1+#5 through `apply` nodes |
| `counterexamples/StaleCase.curry` | #1+#5 through generated case dispatch (needs the `save_copy` epoch check) |
| the `mk` example above | same, minimal |
| the `pick` example (below) | the barrier must not depend on the path that reaches a node |
| `counterexamples/ScopedNestedND.curry` | #1+#3 fail write |
| `counterexamples/ScopedStaleDispatch.curry` | #3 retry redoing outer dispatch |
| the `unjust (Just q)` example | #1+#4 `nondet` guard |
| `main = (y, x)` with `y = Z ? S Z`, `x = True ? False` | a choice is always nondeterministic |

The `pick` example:

```curry
pick :: Bool -> (Bool, ()) -> Maybe Bool
pick True  p = Just (fst p)
pick False _ = Nothing
main = let b = True ? False; p = mk b in (b, pick b p, fst p)
-- expected (True, Just False, False), (False, Nothing, True)
```

Here `n` is first reached through `pick`'s node, not through `p`. A
barrier that tracks the evaluation path instead of allocation stamps
gets this wrong.

**Differential test.** The model's fuzzer found the #1+#5 bug, and
nothing else, from random small programs with shared `let`-bound thunks
and `?`, trying every pair of let-bound values as the goal. The same
generator against Rice, comparing `naive` with each flag set and with
PAKCS, is the cheapest way to check the implementation.

## Open questions for Rice

- **Nondet tracking.** Does Rice's `nondet` really cover every node read
  in multi-field and nested matches (property 1 above)?
- **Admissibility.** Does anything in the pipeline build a cycle through
  a call (`let x = f x`)? If so, those programs fall outside the #1
  theorem.
- **Step granularity.** The model takes one needed narrowing step at a
  time and re-walks retried alternatives. Rice evaluates to head normal
  form and resumes frames. That the two agree is assumed, not proved.
  `ScopedStaleDispatch` is a place where they could differ.

## Implementation status (2026-10-25)

What changed in Rice for each rule above. Tests are in
`tests/programs/regressions/` and `tests/programs/optbench/`.

**Nondet tracking.**
- Rule 2 (sticky flags): `trail_node` and `push_node` (runtime.h) OR in
  `root`'s own flag before deciding, and a case loop's `nondet` starts at
  `root`'s flag instead of 0 (ToC's `enterCase`).
- Rule 3, and rule 1 for nested cases: a nested case starts from `root`'s
  flag, which the enclosing branch's `trail_node` set if it read anything
  nondeterministic. So the enclosing case's flag carries in.
- `apply_hnf`'s `set_copy(root, f)` used to replace `root`'s flag with
  `f`'s, dropping the flags of the forwards on the way to `f`. It now puts
  back the accumulated flag.
- Rules 4 and 5 already held (`choose` always trails and flags).
- The "known issue" (`OPT_NONDET_TRAIL=0` not reaching generated code) was
  already fixed: generated code calls `trail_node`, which goes through
  `needs_trail`.

**#3.**
- Rule 1: `SCOPED_RESAVE` and the FAIL case's fail write
  (`SCOPED_FAIL_TRAIL`) always trail when #3 is on.
- Rule 2: the retry cutoff is per case (`SCOPED_SAVE_CUTOFF` takes the
  trail height when the case starts), not per function. A retry only
  redoes its own case's dispatch, so it only flips choices made since
  that case began.
- Neither counterexample failed on Rice before the fix. Rice lifts nested
  cases into their own functions (`f_CASE0`), so the inner case was
  already a separate rewrite with its own cutoff. The fixes cover nesting
  that isn't lifted. The tests (`scoped_nested_nd`,
  `scoped_stale_dispatch`) guard the shape.

**#4.** No change. `collapse_safe` has the `nondet` guard, and the copy
keeps `root`'s flag and epoch. `copy_unjust` is the test.

**#5.** No change needed: every rewrite already goes through
`needs_trail`. The `save_copy` sites left are free-variable bindings,
`fail_nf`, and #3's fail writes, which always trail.

**Write barrier** (`OPT_WRITE_BARRIER`, default on exactly when #1 and #5
both are):
- The barrier uses option (a). `REWRITE_STAMP()` (runtime.h) computes
  `_stamp = root flagged ? current_epoch : MIN(root.epoch, current_epoch)`.
  Generated code emits it after each branch's `trail_node`, and at function
  entry for writes outside any case, and wraps every `make_*`,
  `make_choice`, `make_apply*` and `free_var` of a rewrite body in
  `STAMPED(...)`.
- `apply_hnf`'s over-applied path stamps the call it builds the same way.
- The runtime's own C rewrites build only constructors, which are never
  rewritten, so their stamps are never read.
- The `#error` is now "#1 and #5 need the barrier". `-DOPT_ALLOW_UNSOUND=1`
  builds the combination without it, only to check that the tests catch
  it. They do: `stale_apply`, `stale_case`, `stale_mk` and `stale_pick` all
  go wrong with it, and are right with the barrier.
- `stale_mk` and `stale_pick` list the tuple's fields in reverse of the
  examples above. Rice normalizes a tuple's last field first, so in the
  original order `b`'s choice came after `p` was evaluated, and the bug
  never happened.

**Path compression** (`OPT_PATH_COMPRESS`, default off): `follow_forward`
(runtime.h). It's used by generated case loops, `settle`, `settle_step`
and `apply_hnf`. It skips only unflagged forwards, and retargets through
`trail_node(r, false)`, which keeps `r`'s flag and epoch. Because flags are
sticky, a flagged `r` is still trailed under #1. That only adds an entry.

**Measuring:** `tests/optbench.sh`, with counters from `-DOPT_STATS=1`
(tests/README.md).
