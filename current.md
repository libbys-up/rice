# Current state (2026-10-11)

Work in progress: the garbage collector, stage 6 of the evaluation-stack
plan. Design, staging and measurements: `src/gc-plan.md`. Leak analysis,
soundness arguments and model-level checks:
`~/curry/papers/unif/proofs/LEAKS.md`. (This file's previous contents,
about the scoped-retry fixes, are in git history at `cf250f0`.)

## Where things stand

Branch `phase1-codegen-and-runtime`, nothing pushed. Collector commits,
newest first:

- `950fb38`: skips forwarding chains (leak 1), adds `-- rice-maxrss: N`
  to `tests/run.sh`, and adds `tests/programs/gc/`.
- `b120628`: the precise copying collector.
- `2687b36`: bump allocation from heap chunks.

Stages 1 (allocator), 2 (collector) and 3 (memory-bounded tests) are
done. Stage 4 (cleanup) hasn't started.

Suites at `950fb38`:

| Run | Result |
|---|---|
| `tests/run.sh` | 70 pass, 4 xfail, 0 fail |
| `tests/run.sh --slow` | 83 pass, 0 fail |
| `RICE_CFLAGS=-DOPT_SCOPED_BACKTRACK=0 tests/run.sh regressions` | 37/37 |
| `RICE_CFLAGS=-DGC_STRESS tests/run.sh` | no crashes or wrong output; 14 long tests time out |

Benchmarks: `cent`, `primesort`, `sort` and `tailsum` are 11-22% faster
than without collection, with peak memory under 80 MB (was up to
6.5 GB). `reverse_builtin` is 49% slower (see below).

## Leak 1: forwarding chains (fixed, `950fb38`)

**What.** A long IO loop kept every step alive. Each step's `bindIO`
node ends up forwarding to the next, and `run_io` roots the first, so a
chain of FORWARD nodes grew one link per step. `gc/io_loop` peaked at
927 MB.

**Fix.** `gc.c`'s `trace_child` skips a FORWARD node on any pointer
*stored in a heap node* (including trail snapshots) if:

1. its nondet flag is clear, and
2. it is on no trail entry. The `GC_TRAILED` bit, in `Node`'s padding,
   is set on every trail `lhs` for the length of a collection.

Roots (the `root` argument, frame slots, C roots, the trail) still
point at the node itself. `io_loop` now peaks at 78 MB and runs 34%
faster. The five benchmarks are unchanged.

**Verified.** The argument is in `LEAKS.md`. It rests on three runtime
properties: evaluation never writes a FORWARD node, readers chase
forwards, and `undo` writes only trailed nodes. Those were checked by
reading the code, not proved.

- Rocq lemmas (`GcLeaks.v`) show that skipping a forward commutes with
  `undo` and that following forwards ends at the same place.
- The model's fuzzer (`GcBench.v`) collects before every step and
  poisons whatever it considers dead. 400 seeds under each of 7 flag
  sets: no differences.
- Dropping condition 2 is caught (4 seeds under all optimizations).
- Dropping condition 1 never changed a result in the model. It is kept
  because of the argument: readers OR in the flag, and losing it could
  leave a dependent write untrailed under #1.

## Leak 2: the trail keeps snapshots alive (open)

**What.** `gc/nondet_pending` (XFAIL in `tests/manifest.txt`): a loop
running while a choice is pending peaks at 824 MB for 200k iterations,
and grows with the loop. Every in-place rewrite of the loop's root
depends on the choice, so it's trailed. The collector traces every trail
entry, so every snapshot, and the list cell and accumulator it points
to, stays alive.

**Ruled out:**

- **A weak trail** (drop entries whose node is unreachable): implemented,
  measured and reverted. It dropped 6% of entries in this test and none
  elsewhere in the suite, and cost a hash over the trail per collection.
- **Keeping only the oldest entry per node** between stop points:
  necessary but not enough. The oldest snapshot still points at the
  list's head, whose *current* contents (the first cons) keep the whole
  consumed list reachable.

**Design** (`LEAKS.md`, "Proposed fix"):

- A *segment* is the stretch of trail between two stop heights. Stop
  heights are choice entries, every cutoff held for `undo`, and every
  commit height held for `pop_to`.
- *View k* is the heap after undoing the top k segments.
- Liveness is traced per view: roots point at every version of a node,
  and a version's children are traced in the views where it is visible.
- Dead entries are dropped, which includes every entry that isn't the
  lowest for its node in its segment.
- A node whose current contents are dead but which has a live entry
  keeps the node; its contents are overwritten with a placeholder.
- The trail is then compacted, and every live height remapped.

**Verified so far (model only).** `GcLeaks.v` proves that undo leaves
each node with its deepest entry's snapshot, so dropping a newer entry
in the same segment changes nothing. `GcBench.v`'s implementation of
the whole design agrees with the baseline on 400 seeds × 7 flag sets.
Both deliberately wrong variants (ignoring segments, tracing only the
current view) are caught. Coverage is thin: only 1,880 entries were
dropped in total, because the random programs build short trails. The
model has no per-entry epochs, no `pop_to`, and no `undo(cutoff)`
stopping mid-trail.

**To implement in Rice:**

1. **Find every live trail height.** Add a frame rep for trail heights
   (`R_TRAIL`, beside `R_INT`). Use it in the `bindIO` and commit frames
   (`prelude.c`), `lazy_unify_step`'s frame (slot 7), `nseq`'s frame
   (slot 7), and generated case-block frames (`SCOPED_SAVE_CUTOFF` in
   `Rice.Codegen.C.ToC`). Audit C-convention code for heights held in
   locals across an evaluation, and give those a registration like
   `GC_ROOT`. (`nf_all`'s `undo(0)` needs none.) Generated functions
   already take `SCOPED_CUTOFF()` after `GC_SAFE_POINT`, so their own
   cutoff is read after any compaction.
2. **Trace by view in `gc.c`.** Compute segments from the live heights
   and choice entries, then trace versions per view instead of tracing
   the trail as roots.
3. **Drop and compact.** Drop dead entries, overwrite dead current
   contents, compact the trail, and remap every live height.
4. **Handle epochs (D4).** `pop` reloads `current_epoch` from each popped
   entry and `pop_to(n)` from entry `n`. If a segment's bottom entry is
   dropped, carry its epoch down or keep a placeholder entry. This only
   matters under `OPT_EPOCH_TRAIL`.
5. **Test in Rice** what the model can't: epochs (`OPT_EPOCH_TRAIL=1`),
   bindIO commits (`pop_to`), and scoped retry stopping mid-trail. Run
   the suite under `GC_STRESS` with each.
6. **Un-XFAIL `gc/nondet_pending`.** Also add a test where the loop's
   root is rewritten many times *across* several choice points, so more
   than one segment is involved.

## The rest of the collector

- **Stage 4 cleanup.**
  - Remove the experimental Boehm path (`#ifdef GC` in
    `runtime/memory.h`, and its Makefile target).
  - Decide whether the "total memory allocations" counter should count
    bytes instead.
- **`reverse_builtin` +49%.** Its 4M-element list stays live, so every
  collection copies everything built so far (about 1.1 GB copied in
  total). Options:
  - a growth factor above 2× (fewer collections, more memory);
  - generations, which would fix it properly.
- **`GC_STRESS` is too slow to cover long tests.** It costs about 1 ms
  per safe point even with a tiny live set: each collection takes a
  fresh zeroed 4 MB chunk and poisons the old one. So 14 long tests
  only time out under it. Reusing chunks, or poisoning only what was
  used, would make the stress run cover them.
- **Tuning.** Chunk size (4 MB) and the threshold (64 MB, then 2× live)
  are first guesses.
- **Safe points only at `_hnf` entries.** Still unconfirmed that no loop
  allocates unboundedly without entering a function. Write a test that
  allocates heavily inside one runtime loop.
- **The proofs side.** `LEAKS.md`, `GcLeaks.v` and `GcBench.v` are
  uncommitted in the proofs repo. Not proved:
  - that skipping a forward keeps `deref_nd`;
  - D2-D4 (the per-view liveness);
  - an end-to-end simulation of a collecting machine.

## Hazards found along the way

- Two `rice` builds or `tests/run.sh` runs with different `RICE_CFLAGS`
  must not run at once: they share `runtime/*.o` (and the kics2 lib's
  `Prelude.o`).
- Don't run `make` in `runtime/`. It rebuilds the objects with `-g` and
  no `-O2`, but leaves `rice`'s `*.o.flags`, so later programs link
  unoptimized code. If it happens: `rm runtime/*.o runtime/*.o.flags`.
- In the proofs repo, `vm_compute` over 400 seeds segfaults. Run chunks
  of about 25 seeds with `ulimit -s 65520`.

## Loose ends (not the collector)

- `gc/strict_fold` is slow: about 1.7 µs per element, against 0.06 µs
  in `tailsum`. Possibly `even`/`map` dispatching through type-class
  dictionaries. Worth profiling.
- `=:<=`'s settle loops treat a `CHOICE_TAG` node as a value
  (`src/explicit-stack-plan.md`). Possibly a latent bug; it needs a test.
- `git stash` holds the "lazy frames experiment". It can probably be
  dropped, since the collector relies on eagerly pushed frames.
