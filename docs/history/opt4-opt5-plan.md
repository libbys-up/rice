Plan: making optimizations #4 and #5 actually fire
===================================================

Written 2026-10-02. Numbering follows `docs/history/backtracking-optimizations.md`.
Background and the formal side live in `~/curry/papers/unif/proofs/`
(`docs/status.md`, `Machine.v`, `Opt5_EpochTrail.v`, and
`copy_forward_optimization.md` for #4). `opt_conflict.md` (this repo)
covers the #1+#5 interaction.

What the proofs established, and what is still open:

- **#5 alone is proved sound** on the model
  (`Opt5_EpochTrail.epoch_trail_sound`: exact result equality with
  baseline). Its trail rule does not depend on #1. The model's trail
  decision is `should_trail = (#1 off || nondet) && (#5 off || stamp < epoch)`,
  and the two halves are independent filters (`should_trail_conj`).
- **#1 + #5 together, without a write barrier, is unsound**
  (`scen_both_stale`, `counterexamples/StaleApply.curry`).
- **#4 has no isolation proof yet.** The current guard (copy only a
  constructor with `nondet == false`) agrees with baseline under fuzzing.
  A more aggressive version is plausible but unproved. See the proofs-side
  write-up.

------------------------------------------------------------------------------

#5: why it never fires today
----------------------------

1. Only one trail site checks the epoch: `push_node`, reached only from
   `apply_hnf`. The main trail site, generated case code's
   `if(nondet) save_copy(root)` (`ToC.curry` `failBlock`/`showConsBranch`),
   does not, and neither do `prelude.c`'s root-rewrite trails. So #5
   could only ever affect `apply` nodes, which is why `bench.sh` never
   saw it skip anything.
2. `OPT_NONDET_TRAIL=0` did not turn #1 off in generated code: the
   `if(nondet)` gate was emitted unconditionally. Adding an epoch check
   to `save_copy` would therefore have produced #1+#5 (unsound), not #5.

Plan for #5
-----------

- **5.1 One trail decision, mirroring the model's `should_trail`.**
  `runtime.h` gets `needs_trail(root, nondet)` and `trail_node(root, nondet)`.
  Every *root-rewrite* trail goes through it: the generated gates
  (`failBlock`, `showConsBranch`, `SCOPED_RESAVE`), `push_node`, and
  `prelude.c`'s `strictApply`/`&`/`cond`/`nonstrictEq` gates. `trail_node`
  still ORs `nondet` into the node's flag when it skips, because #3 and
  #4 read that flag. **[DONE 2026-10-02]**
- **5.2 Leave choice points and variable bindings always trailed.**
  `choose()`, `push_choice`, the `push_frame` before narrowing a free
  variable, and the unification binding sites (`prelude.c` `unify`/
  `lazy_unify_step`) keep calling `save_copy` unconditionally. The model
  doesn't cover `=:=`/`=:<=`, so the proof doesn't license skipping them
  yet. `fail_nf` also stays unconditional (always sound, just not
  optimized). **[DONE: left as-is]**
- **5.3 Forbid #1+#5 without a barrier.** `runtime.h` has an `#error` for
  `OPT_NONDET_TRAIL && OPT_EPOCH_TRAIL`, so building #5 requires
  `-DOPT_NONDET_TRAIL=0`. `bench.sh`'s `all-on` config now leaves #1
  off. Lift this once option A (write barrier) from `opt_conflict.md` is
  implemented and tested. **[DONE 2026-10-02]**
- **5.4 Check Rice's epoch handling on retry against the model.** The
  model bumps the epoch when it retries an alternative
  (`S (cp_saved_epoch)`). Rice's `pop` restores the epoch saved when the
  frame was pushed. A `push_choice` retry never bumps it again, while
  `choose()` side 1 does. Probably fine, since the popped frame is gone,
  but it needs an argument or a change to match the model. **[OPEN]**
- **5.5 Tests and measurement.**
  - Add `StaleApply.curry`/`StaleCase.curry` to `tests/programs/regressions/`.
    **[DONE]**
  - Run the full suite under `-DOPT_NONDET_TRAIL=0 -DOPT_EPOCH_TRAIL=1`.
    **[DONE 2026-10-02]** Fast suite: 51/51 pass in all three configs
    (default; #1 off; #1 off + #5 on), with the 3 known xfails. Both stale
    programs give PAKCS's answers in every config. (`tests/run.sh` used to
    word-split a multi-flag `RICE_CFLAGS` into a bare `-DOPT_...` argument;
    it now passes one `--cflags` per flag.)
  - Add a debug-build counter of skipped trails, so we can see #5 firing.
    **[OPEN]**
  - Re-measure. The old `naive` config wasn't naive in generated code,
    so every earlier #1 number compared #1 against #1. **[OPEN]**

**Found while implementing 5.1: #1 was baked into more than the
`if(nondet)` gate.** A generated function body whose root write isn't
inside a constructor-case branch (no top-level `case`: let-lifted
functions, `IExempt`, literal-case branches and their fail default)
never trailed at all. Several `prelude.c` primitives didn't either
(`failed`, `ensureNotFree`, `constrEq`, the `show*`/`read*Literal`
family, `readFile`). Under #1 that's justified: nothing nondeterministic
was read. With #1 off, those are baseline trails that were simply
missing, and #5 then recreated the #1+#5 failure. `StaleApply.curry`
stayed wrong under `-DOPT_NONDET_TRAIL=0 -DOPT_EPOCH_TRAIL=1` until they
were added: its `o` is a let-lifted function, `main_LET6`, that rewrites
an old node to point at the young `pick x` node. Fix:
- Codegen: `ToC.curry`'s `uncaseTrail` emits `trail_node(root, false)`
  right before any such write.
- `prelude.c`: `trail_node(root, false)` in those primitives, via a new
  `overwrite_root` helper for the `memcpy` ones.

Both are constant no-ops when #1 is on, so the default build is
unchanged. IO primitives (`returnIO`, `bindIO`, `getChar`, `putChar`)
were left alone.

**#1 bug in unification, found and fixed 2026-10-03.** `constrEq`
(`=:=`) forced both sides with `nf` and then rewrote root without
tracking nondet, so under #1 (the shipped default) root was never
trailed. `(True ? False) =:= True` printed `True` twice. Fixes:
- `unify_step` now accumulates nondet over every node it visits,
  forwards included, and sets it whenever it binds a free variable.
  `constrEq` passes that to `trail_node`.
- `lazy_unify_step` (`=:<=`) had the same hole in its plain binding
  branch (the narrowing branch already set nondet). It now reports
  nondet on every binding.

Regression tests: `constreq_choice`, `constreq_shared`,
`constreq_bind_choice`, `constreq_bind_after_choice`,
`lazyunify_bind_after_choice`. Expected outputs were checked against
PAKCS.

Related epoch bug: the `show*`/`read*Literal` primitives and
`setCurryString` overwrote root with a raw `memcpy` of a fresh node,
stamping the old root with the fresh node's epoch. They now use
`set_copy`, which keeps root's epoch.

A real bug fixed along the way (5.1): `push_node`'s trail snapshot was
made with `copy()`, which stamps the snapshot with `current_epoch`.
`undo()` restores a frame by `memcpy`, so a restored node came back
with its *trail-time* epoch instead of its allocation epoch. An old node
would then read as young, and its next mutation would be wrongly skipped.
Snapshots now keep the node's own epoch, the same way `save_copy`'s
`memcpy` already did.

------------------------------------------------------------------------------

#4: why forwarding nodes are still everywhere
---------------------------------------------

1. The target is usually not evaluated yet when the collapse happens.
   For `id x = x`, `x` is still FUNCTION_TAG, so `collapse` forwards.
   Later something evaluates `x` through the forward, but `root` stays a
   forwarding node permanently.
2. Forward chains aren't followed. `collapse_safe` doesn't exclude
   FORWARD_TAG, so "copying" a forwarding node just copies the
   indirection. The model has the same issue: `graph_at` with an empty
   path doesn't deref, so `env v` can be a `CInd`.
3. Any target with nondet set always gets a forward, which covers
   everything downstream of a choice.
4. Some `prelude.c` primitives call `set_forward` directly instead of
   `collapse`: `returnIO` (`:238`), `&` (`:399`), `cond` (`:458`),
   `ensureNotFree` (`:795`).

Plan for #4 (least to most new proof needed)
---------------------------------------------

- **4.1 Follow the forward chain first.** Before deciding, follow the
  chain the way the model's `walk_safe` does, only through hops with
  nondet false. Route the four `prelude.c` value-return sites through
  `collapse`. The unification binding sites (`prelude.c:527, 533, 636`)
  must stay forwards. Justified by `compress_preserves_deref` plus the
  existing copy argument.
- **4.2 Evaluate the target before collapsing.** Emit
  `HNF_SETTLE(target); collapse(root, target)`. Root's `_hnf` contract
  already needs the target's value, so this moves work earlier but adds
  none. Caveats:
  - It turns a tail position into a non-tail call. Under `OPT_TAIL_JUMP`,
    keep the forward, or `id (id (id ...))` gets deep C recursion back.
  - The model's `fire_rule` TVar case would need to collapse after the
    target is in HNF, so the proofs keep matching the code.
- **4.3 Relax `!target.nondet` (unproved; fuzz in the model first).**
  Always copy an HNF constructor, but root takes on the target's flag
  (`root.nondet |= target.nondet`) and its write is trailed under the
  5.1 rule. Root's trail entry is pushed after the choice that bound the
  target, so backtracking past that choice also restores root to the
  original call. Only CHOICE_TAG, FREE_TAG and unevaluated calls still
  need a forward. Keep it behind its own flag value (e.g.
  `OPT_COPY_COLLAPSE=2`) until proved. Interaction with #5 (a young root
  goes untrailed) needs its own argument.
- **4.4 Measurement.** A copy doesn't allocate, so `bench.sh`'s
  allocation column can't show #4. Add debug counters for forwards
  created, copies made, and forward hops followed.

Forwards that remain even after 4.1-4.3:
- `choose()` (`runtime.c:517`): every resolved `?` becomes a forward to
  its alternative, with nondet set. If 4.3 holds, the same argument
  (`choose()` always trails the choice node) may let it copy an
  evaluated constructor result.
- Collapsing onto a free variable: the binding mutates the variable in
  place and root has to see it, so this forward is needed.
- Unification bindings: variable-to-variable needs a forward;
  variable-to-constructor could copy, but the model doesn't cover it.
- Under `OPT_TAIL_JUMP`, where 4.2 is off.

On path compression as an alternative: the model's `compress` only
skips hops with nondet false, which are exactly the ones 4.1/4.2 already
avoid. The forwards left over (`choose`, bindings) all have nondet set.
Compressing through them needs the same "root's own write is trailed"
argument as 4.3, and a compressed root is still one hop, not zero.
Compression also isn't proved: only `compress_preserves_deref`, and the
fuzzer never checked that it fires. With #1 off, it also relies on #1's
unproved insensitivity lemma (see the proofs-side write-up). So
compression isn't a cheaper fallback.

Suggested order: 5.1 -> 5.3 -> 5.5 -> 4.1 -> 4.4 -> 4.2 -> 4.3.
