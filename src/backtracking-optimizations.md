Backtracking Optimizations
==========================

Five optimizations to the backtracking/non-determinism machinery described in
`archetecture.md`, written up for the goals stated when this work started:
(1) determine whether each is valid, (2) determine whether they're orthogonal,
(3) implement them behind independent toggles and measure. Two of the five
turn out not to be valid exactly as first stated — both have a real, useful
core, narrowed to where the argument actually holds. That's not a rejection
of the idea, it's the boundary the implementation needs to respect. A sixth
idea — caching, deliberately kept out of the initial five because it's
unsound as a blanket rule but too promising to drop — is recorded at the end.

Throughout, "valid" means: preserves the set (and multiplicity) of solutions
Curry's semantics says the program has. Losing solutions or duplicating them
is a correctness bug, not a slowdown, and non-determinism is exactly where
that kind of bug hides silently — an optimization here can look like it works
on every test that only checks the first solution.

------------------------------------------------------------------------------

1. Nondet-gated trailing
--------------------------

**Statement**: an expression whose reduction never touches a `CHOICE` or
`FREE` node is deterministic — it produces the same result every time it's
computed — so nothing about reducing it ever needs to be undone, and no
rewrite frame needs pushing for it.

**Status**: already implemented, already toggleable. This is exactly
`push_node` in `runtime.h`: every `hnf` loop accumulates a local `nondet`
flag (OR'd from `scrutinee.n->nondet` each iteration, forced `true` on
`CHOICE_TAG`/`FREE_TAG`), and only pushes a rewrite frame if that flag ended
up set. The `#if TEST == NO_OPTS` / `#else` split in the same file is already
the toggle — `NO_OPTS` always pushes, `PUSH_NONDET` (and above) gates it.
It's never been benchmarked.

**Validity**: sound without qualification. `undo()`'s entire purpose is
restoring a node so a *different* alternative can be tried. If nothing about
how a node was reduced depended on any choice, there is no "different
alternative" — recomputing it would always yield the identical result, so
leaving the already-reduced form in place on backtrack is not observably
different from having undone and redone it.

**Example**:
```
f x = (x + 1) ? (x + 2)
```
Evaluating `x + 1` — unboxing `x`, adding, reboxing — touches no `CHOICE`/
`FREE` node itself, so none of *that* work needs a rewrite frame, even though
`f x` as a whole is non-deterministic because of the outer `?`. The `?` node
itself still unconditionally pushes (see next section) — this only saves the
frames for the deterministic arithmetic underneath it.

------------------------------------------------------------------------------

2. Eager tail dispatch
------------------------

**Statement**: when a function's body reduces to a call in tail position
(`f x = g x`), there are two ways to finish: (a) build a `g`-node at `root`
and return, relying on whatever loop called `f_hnf` to notice `root` is still
`FUNCTION_TAG` and dispatch again; or (b) call `g_hnf(root)` directly, inline,
before returning. Rice does (b).

**Status**: already Rice's behavior (per the dissertation's `apply_hnf`:
`if (missing == 0) { HNF(root); }` right after building the fully-applied
copy, rather than just returning). Not yet toggleable or measured.

**Validity — sound, with a real caveat, not just semantic hand-waving**:
producing the same graph either way, so results are identical. The caveat is
about *resource* boundedness, not results. Option (b) calls `g_hnf`
*directly* — a statically-known C function, not through the `HNF` macro's
indirect `symbol->hnf` dispatch — which is why it's faster (no indirect call,
no redundant tag re-check by the caller's loop). But chaining `g_hnf(root);
return;` for every tail call only avoids growing the *C* call stack if the C
compiler actually performs sibling-call elimination on that call — which
requires strict tail position (nothing after the call, nothing to clean up)
and is common at `-O2`+ with clang/gcc, but is not something the C standard
guarantees, and can silently stop happening under debug builds or with
sufficiently unusual surrounding code. Option (a) — return, let the caller's
`while(true)` loop redispatch — is a genuine trampoline: it cannot stack
overflow regardless of what the C compiler decides to do, because the loop is
explicit, not relying on TCO. A tightly tail-recursive Curry function
compiled under option (b) with a C compiler (or optimization level) that
doesn't eliminate the sibling call *will* grow the C stack linearly with
recursion depth and can crash on deep recursion that Curry's own semantics
says should run in constant space.

This means "measure it" here should include more than throughput: verify,
under whatever the actual build configuration is (likely `-O2`, but check),
that a long tail-recursive loop doesn't blow the C stack. If it doesn't
reliably hold across build configurations, that's worth knowing before
shipping this as the only option, not after.

**Orthogonality**: independent of the others. It's a question of *how* a
reduction hands off to the next one; trailing decisions (#1, #5) are made
about whichever node ultimately settles `root`'s final identity, regardless
of how many inline hops it took to get there — `root` stays the same node
object throughout a chain of tail dispatches (`set_g` mutates it in place),
so exactly one trail decision applies to it either way.

------------------------------------------------------------------------------

3. Scoped early backtracking (generalizing old_rice's `unify`)
------------------------------------------------------------------

**Statement as given**: remember the backtracking stack's height when
starting to reduce an expression; if that reduction fails, jump straight past
everything pushed during it (`undo` with that height as a cutoff) instead of
letting the failure bubble up through the full call structure before
backtracking begins.

**Status**: the mechanism already exists, unused for this. `runtime.h`
already has `EARLY_BACKTRACKING` as a `TEST` level, and `undo(int cutoff)` in
`runtime.c` already has the `#if TEST == 3` branch that stops at `cutoff`
instead of searching to the bottom of the stack. What's missing is (a) code
that actually remembers a height and passes it as that cutoff, and (b) —
this is the part worth being careful about — a clear answer to *when* this is
sound, because it is not sound as a blanket rule.

**Validity — revised after actually trying to build a counter-example against
it, worth recording why**: the original framing here ("jump past every choice
point created during E's reduction *without trying* their alternatives")
doesn't match what `undo(cutoff)` actually does. Reading it again: it still
pops and *tries* the first choice-marked frame it finds, exactly like
unbounded `undo` — the cutoff only changes what happens if it *doesn't* find
one before reaching that height (gives up and reports "no solution in scope"
instead of reaching further down into older, unrelated choice points).
Nothing *inside* `[h, top]` gets skipped; every alternative in scope still
gets tried, just as thoroughly as unbounded search would.

That changes the answer. Used *purely* as a search-depth bound — "look for a
retriable choice point down to height `h`, then report an ordinary `FAIL`
upward through the normal mechanism, nothing else" — this is sound for **any**
expression, not just `(=:=)`. It can't drop a solution within its own scope
(everything there still gets tried), and there's no coherent way for it to
reach a solution *below* `h` from deep inside nested reduction anyway —
`undo` only makes sense called from `nf_all`'s own top-level retry loop, which
re-runs the whole computation from scratch, not from wherever the C call
stack happened to be paused. So the unify-specific "both sides fixed for the
whole call" argument turns out not to be load-bearing for *this* version —
it's sound more broadly than the original writeup claimed.

Where unsoundness can actually enter is a different, stronger addition:
**caching** the outcome — using the bound to conclude "this code, at this
point, has no solution" and *skipping* re-entry into it on a later retry of
some *older* choice point it depends on. That's no longer "bound a search,"
it's "memoize an outcome," and it needs the unify-specific argument (nothing
inside *or* outside the call can change the answer) re-earned, because it
generally doesn't hold. Shape of the failure: some `E` reads a free variable
bound by an older choice point created before `E` started; `E` fails under
that choice's first alternative but would succeed under its second; caching
"`E` has no solution" and skipping it on the retry loses that solution. I can
state that shape with confidence but won't hand-wave a specific traced
example for it the way I can for #4 below — pinning down exact backtracking-
stack frame ordering for a caching variant needs verifying against a working
`undo`/`choose`, not more manual tracing (the runtime doesn't build yet, and
getting this exactly right by hand is harder than it looks — this section's
own history is evidence of that).

**So, concretely: plain depth-bounded `undo`, with no memoization attached,
is valid as a general mechanism, not just for `(=:=)`.** If it ever grows a
caching layer on top, that specific addition needs the closed/fixed-target
argument again, and should probably stay scoped to things like `(=:=)` where
that argument actually holds. (The caching version, if it's ever wanted, is
really conflict-directed backjumping from the CSP literature — tracking
*which* choices a failure actually depended on, rather than assuming
"everything since this height" is safe to skip on retry. A bigger mechanism
than what's described here, worth knowing exists if plain depth-bounding
turns out to be too conservative in practice.)

**Orthogonality**: composes cleanly with #1 and #5 — in fact positively:
whatever they prevent from being pushed in the first place is fewer frames
`undo(cutoff)` has to pop through, so scoped backtracking gets cheaper (not
just independently correct) when combined with either. No conflict with #2
or #4.

------------------------------------------------------------------------------

4. Copy instead of forward, at collapse points
--------------------------------------------------

**Statement as given**: when a function reduces to one of its own arguments
unchanged (`id x = x`, or a `case` branch `C v -> v`), physically copy the
target's current node contents into `root` instead of making `root` a
`FORWARD` alias — removing a permanent indirection hop for every future
access.

**Concrete counter-example**, traced fully — this one doesn't depend on any
subtle assumption about backtracking-stack ordering, just on what "copy"
means the instant it happens before the source is resolved:
```
id' :: a -> a
id' y = y

main :: (Bool, Bool)
main = let x = True ? False
       in let z = id' x
          in (z, x)
```
Correct (forwarding) behavior: `x` is one graph node. `z = id' x` makes `z` a
`FORWARD` to that same node, not a second choice. Forcing the pair forces `z`
first — chases the forward, resolves `x`'s choice to `True`, pushes the
`False` alternative — then forces `x` directly, already resolved, sees
`True` too: `(True, True)`. Backtracking flips `x` to `False`; both `z` (via
the forward) and `x` see it: `(False, False)`. **Correct solution set:
`{(True,True), (False,False)}`** — `z` and `x` can never disagree, because
they're the same choice.

Under naive copying: `id'_hnf` runs before anything else has forced `x`, so
`x` is still an unresolved `CHOICE_TAG` node at that moment. Copying
duplicates that unresolved structure into `z` wholesale — `z` and `x` are now
two independent choice nodes, each capable of resolving to `True` or `False`
on its own. Forcing `z` resolves *its own* copy to `True`, pushing *its own*
`False` alternative. Forcing `x` separately resolves *its own, separate*
copy — also `True` first (matching, so far, by coincidence), pushing *its
own* `False` alternative. First result: `(True, True)`. Backtracking pops the
most-recently-pushed frame — `x`'s, since `x` was forced second — and flips
*only* `x` to `False`, leaving `z` untouched at `True`: **`(True, False)`** —
a combination that cannot exist under real Curry semantics, since `z` and `x`
were supposed to be the same shared value. Exhausting both independently
produces all four combinations. **Naive-copy solution set:
`{(True,True), (True,False), (False,True), (False,False)}`** — two
fabricated solutions, from a program with exactly one coin flip in it.

**Validity — not valid unconditionally, and the reason is the same
"ground" property already load-bearing elsewhere in this pipeline**:
forwarding preserves *sharing* — `root` and the target become two names for
the literal same evaluation. Copying breaks that the moment the target isn't
already fully settled: if `x` is still `FUNCTION_TAG`/`CHOICE_TAG`/otherwise
unresolved when copied, `root`'s copy and the original `x` become two
independent locations that no longer share subsequent evaluation. Two
consequences, one merely wasteful and one actually unsound:

- **Wasteful**: if both get forced later via their now-separate references,
  whatever computation `x` represents gets redone twice — exactly what graph
  reduction with sharing exists to avoid.
- **Unsound**: if `x` is or becomes non-deterministic before it's resolved,
  the copy and the original independently make *separate* non-deterministic
  choices later, turning one shared choice into the cross product of two —
  silently changing the set and multiplicity of solutions the program
  computes. This is a correctness bug, not a performance regression.

This is the *identical* condition already governing safe substitution in
`Rice.Optimize.Inline` (`subGrounded`/`ground` — a source-level transform is
safe to duplicate a reference to exactly when the thing being duplicated is
already a fully-evaluated, non-deterministic-free value). It's not a
coincidence that it reappears here; it's the same underlying property —
"safe to duplicate without duplicating deferred work" — showing up at the
runtime-graph level instead of the source-transformation level. It's also
exactly why natural/CRWL term-rewriting semantics can state a collapsing rule
as "copy the reduct" without this caveat: a formal term-rewriting semantics
doesn't model sharing at all, so duplicating a redex is free at that level of
abstraction. Rice's runtime is a graph reduction machine specifically
*because* it needs to model sharing for both efficiency and non-determinism
correctness — this is exactly the "a bit different" you flagged.

**The valid, narrowed version**: copy is sound specifically when the
collapse target is *already*, at the moment of collapse, in HNF and
`nondet == false`. In that case a shallow copy only duplicates the top node;
its children are still shared by pointer (the copy's `children` array holds
the same pointers), so nothing below the top level loses sharing, and the top
level itself is done — nothing will ever dispatch `hnf` on either copy again.
This condition is checkable using exactly the same `nondet` bookkeeping #1
already maintains — meaning #4's *cheapest* implementation depends on #1
being enabled (see orthogonality below).

Even narrowed to that condition, this is a genuine eager-vs-lazy trade, not
an obvious win the way #1–#3 are (which strictly remove work): a copy costs
an `alloc` + `memcpy` of a full `Node` (48 bytes, per the measurement in
`archetecture.md`) paid immediately, against saving some number of pointer
chases later — a number that could be zero if the value turns out to be dead
or accessed only once. This one specifically needs the measurement to know
if it's a net win at all, not just how big a win.

**Orthogonality**: depends on #1's `nondet` flag for its safety check (not
#5's epoch — an already-deterministic, already-HNF value never needed
trailing in the first place, regardless of age, so age adds nothing to this
particular check). Independent of #2 and #3.

------------------------------------------------------------------------------

5. Time-stamped (epoch) trailing
------------------------------------

Carried over from the backtracking-stack discussion: WAM's actual trail
condition — trail a binding only if the variable is *older* than the most
recent choice point, since anything younger is discarded wholesale when
backtracking resets the heap pointer — doesn't transfer to Rice's allocator
directly (`GC_MALLOC`/`calloc` don't give address-order-equals-allocation-
order the way a bump-pointer arena does). The address-comparison mechanism
doesn't transfer; the underlying soundness argument does, via **time-
stamping** — the standard fallback used in Prolog implementations whenever
address comparison isn't available (e.g. under a copying GC, which is the
same situation Rice is in).

**Mechanism**: a global counter incremented once per choice point created
(not per allocation). Every node stamped with the counter's value at `alloc`
time. Every choice point snapshots the counter when pushed. A rewrite frame
for some node only needs pushing if that node's stamp predates the *active*
choice point's stamp — i.e. it existed before the most recent choice point,
so backtracking past that choice point can't discard it automatically.

**Validity**: sound by the same soundness argument as WAM's version — if a
node's own allocation postdates the active choice point, nothing older than
that choice point can hold a reference to it (the only way something older
could reach it is by having a pointer to it written into an older node's own
cell, which is itself a mutation that would independently be trailed) — so
once we backtrack past that choice point, the young node becomes unreachable
regardless of whether its mutation was undone. Rice doesn't get WAM's
"reclaim it instantly by resetting one pointer" benefit (no bump-pointer
heap), but reclamation is already handled generically by the GC once the node
is unreachable — this optimization is purely about not pushing (and later
popping/`memcpy`ing) the frame in the first place.

**Cost, measured not assumed**: `sizeof(Node)` is 48 bytes on this platform,
with 3 bytes of dead padding already sitting between `nondet` and `symbol`
(verified with a standalone C program, not inferred from the struct
definition) — a packed epoch counter fits there with **zero** growth to
`Node` itself. The real cost is in the choice-point frame format: each
choice point needs to save (and, on backtracking *past* it, restore) the
active-epoch value that was in effect before it existed — `FieldPair`
(`stack.h`) needs one more field, at least for `choice == true` frames.

**Example** — this is the common case, not a corner case: `f (x ? y)` builds
a fresh `?` node as an argument. If something forces it later in the same
epoch (no intervening choice point), that forcing currently pushes a rewrite
frame for a node that was never reachable from outside this one reduction to
begin with — the epoch check catches this every time nested `?`/narrowed
free variables get built and consumed within one un-interrupted stretch of
evaluation.

**Orthogonality**: complementary to, not redundant with, #1 — and strictly
more powerful combined. #1 alone says "skip trailing if nothing
non-deterministic was touched." #5 catches a case #1 *can't*: a node that
*is* inherently non-deterministic (a freshly-built choice node itself, being
`choose`d) but is also younger than the active choice point — `x ? y` built
fresh inside `f`'s own call, per the example above. The combined, correct
rule is "trail iff non-deterministic *and* older than the active choice
point" — #5 tightens #1's criterion with a second, independent condition,
rather than overlapping it. Positive interaction with #3 (fewer pushed frames
means less for a scoped `undo` to pop through). No interaction with #2 or #4
beyond #4's own dependence on #1 noted above.

------------------------------------------------------------------------------

6. Dependency-tracked caching (deferred — kept deliberately, not implemented yet)
------------------------------------------------------------------------------

Not part of the four to build first. Recorded here because it's unsound as a
blanket rule but has a real, established payoff elsewhere, and a concrete
(if bigger) path to making it sound — worth having written down before it's
forgotten, not worth blocking the simpler four on.

**What it is, precisely** (see the discussion that produced this
clarification): recording the *outcome* of a locally-exhausted search — "this
reduction has no solution" — and reusing that recorded answer on a later
re-entry instead of re-searching. This is a strictly different thing from
plain depth-bounded search (#3): depth-bounding never remembers anything
across separate `undo` calls, it just bounds one search. Caching remembers
across them.

**Why it's unsound as stated**: reusing a cached "no solution" skips the
normal trail entry that would otherwise let that outcome be reset if
something *outside* the cached computation's own scope later changes in a way
the computation actually depended on. If the computation is genuinely closed
(depends on nothing outside its own scope — the `(=:=)` case), there's
nothing to miss and the cache is safe forever. If it isn't closed, the cached
`FAIL` can outlive the context that produced it and silently suppress a
solution a fresh re-derivation would have found — the `f x = (x, g x)` shape
from before, but now the bug is "the stale answer never gets invalidated"
rather than "the search skipped something on one pass."

**Why it's worth keeping anyway**: if the same locally-exhausted
subcomputation gets genuinely re-explored many times across a large outer
search — which is exactly the situation that makes naive backtracking slow in
practice — correctly-scoped caching is a large, well-established win, not a
speculative one. This is *tabling* in logic programming (SLG resolution,
XSB Prolog's tabling, Mercury's `:- pragma memo`): caching subgoal results
across a search, made sound specifically by tracking what a cached result
actually depends on and invalidating precisely that, rather than assuming
either "never invalidate" (unsound, what's described above) or "invalidate
everything on any backtrack" (safe but gives back all the savings).

**The path to soundness, for later**: tag each cached result with the set of
external choice points it actually read from (a *dependency set*) while it
was computed. On backtracking into some choice point, only invalidate cached
results whose dependency set contains it — not every cache entry
unconditionally. A computation with an empty dependency set (nothing read
outside its own scope) is exactly the `(=:=)`-shaped case and never needs
invalidating at all. This needs new bookkeeping the runtime doesn't have
today — recording *which* choice points a computation observed, not just
*whether* it observed any (`nondet`) or *when* it was born relative to the
active one (#5's epoch). Worth noting: #5's epoch-stamping machinery is a
plausible foundation to extend for this rather than a separate mechanism from
scratch — both are fundamentally "what does this computation's correctness
depend on," just at different granularity (one timestamp vs. a set of
specific choice points).

**Status**: explicitly deferred. Whether the dependency-tracking overhead
ends up cheaper than the redundant recomputation it would save is itself an
empirical question, and answering it well depends on first having #1–#5
measured and a real sense of how much time backtracking-heavy programs
actually spend re-exploring locally-dead subcomputations. Revisit after that.

------------------------------------------------------------------------------

Orthogonality summary
------------------------

|         | #1 nondet | #2 tail-dispatch | #3 scoped backtrack | #4 copy-collapse | #5 epoch trail |
|---------|-----------|------------------|----------------------|-------------------|-----------------|
| #1      | —         | independent      | positive (fewer frames to scope-undo) | **depends on** (#4 needs #1's flag) | complementary (tightens #1's criterion) |
| #2      |           | —                | independent          | independent        | independent      |
| #3      |           |                  | —                     | independent        | positive (cheaper scoped undo) |
| #4      |           |                  |                       | —                   | independent (doesn't need #5) |
| #5      |           |                  |                       |                     | —                |

No pair is *unsound* in combination. The one real dependency is #4 on #1 —
#4's safety check is naturally expressed using #1's `nondet` bookkeeping, so
implement #1 first. Everything else can be built, toggled, and measured in
any order.

Implementation plan
-----------------------

**Toggle architecture**: the existing `TEST` macro (`NO_OPTS` /
`PUSH_NONDET` / `EVAL_KNOWN_CALLS` / `EARLY_BACKTRACKING`) is an ordinal
progression — each level implies the ones before it, which is exactly wrong
for measuring five things that are mostly independent and need a real
factorial comparison. Replace it with independent compile-time flags —
`OPT_NONDET_TRAIL`, `OPT_TAIL_JUMP`, `OPT_SCOPED_BACKTRACK`,
`OPT_COPY_COLLAPSE`, `OPT_EPOCH_TRAIL` — each individually `#define`-able,
so any of the 32 combinations can be built and benchmarked, including the
ones the orthogonality table above predicts should compose (validating the
predictions is itself part of "measure it"). Compile-time, not a runtime
flag: a runtime branch on every trail decision would add overhead that
specifically pollutes the measurement these are meant to produce.

**Suggested build order**, given the one real dependency:
1. #1 (nondet trailing) — already implemented, just needs the flag split out
   and benchmarked on its own first, since #4 needs it.
2. #5 (epoch trailing) — independent of build order otherwise; needs the
   `FieldPair` extension and the active-epoch save/restore on choice-point
   push/pop worked out first, since that's the fiddliest part.
3. #4 (copy-collapse) — once #1 exists, gate it on `nondet == false` at
   collapse points.
4. #2 (tail dispatch) and #3 (scoped backtrack) — independent of the above,
   can be done in parallel with them. #3, as plain depth-bounded search with
   no caching attached, applies generally, not just to `(=:=)` — see the
   revised validity discussion above.

For measurement: throughput/allocation-count comparisons across the 32
combinations on a benchmark set (old_rice's dissertation already has one,
adapted from kics2's own test suite — worth reusing rather than building a
new one from scratch), plus, specifically for #2, a deep-tail-recursion stack
safety check across build configurations, not just a speed number.

**#6 (dependency-tracked caching)** stays out of this round entirely — it's a
bigger mechanism than a toggle flag, and deciding whether it's worth building
depends on what #1–#5's measurements show about how much time is actually
spent re-exploring locally-dead subcomputations. Revisit once those numbers
exist.
