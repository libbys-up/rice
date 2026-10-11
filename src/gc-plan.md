Plan: a precise copying garbage collector
=========================================

Written 2026-10-08. The last stage of `explicit-stack-plan.md` (stage 6).
Builds on `field-reps-plan.md` (every node child and frame slot is known
to be a pointer or a raw value) and on the evaluation machine (evaluation
state lives in frames, not on the C stack).

Today nothing is ever freed: `alloc` is `calloc`. A million-step IO chain
peaks at about 2.5 GB, and `calloc` is most of the run time in a profile
of `sort`. Goals:

- reclaim garbage, so long-running programs run in bounded memory;
- allocate by bumping a pointer instead of calling `calloc`;
- keep it simple and precise: no conservative scanning, and no
  cooperation from C code beyond a short, explicit list of sites.

Non-goals for now: generations, incremental or concurrent collection,
compaction tuning.

------------------------------------------------------------------------------

The key decision: collect only at safe points, never inside `alloc`
-------------------------------------------------------------------

Generated code and runtime routines hold node pointers in C locals
between allocations: a block builds several nodes in a row, a case block's
dispatch loop calls `choose` (which allocates a trail snapshot), narrowing
allocates free variables, and so on. A collection inside any of those
allocations would move nodes out from under those locals.

So **allocation never collects**. It bump-allocates from the current
chunk, and when the chunk is full it takes a fresh chunk (never moving
anything). Collection happens only at a **safe point**, when
"bytes allocated since the last collection" has passed a threshold.

The safe point is **the entry of every `_hnf` function** (generated or
hand-written). Every machine code path reaches one regularly, and at that
moment the live pointers are exactly:

- the `root` argument;
- every frame on the machine stack, traced through `FrameInfo.reps`;
- the trail (`bt_stack`);
- registered C roots (below).

C locals of whatever code ran before are dead by then: control reached the
entry by a `musttail` jump (their function is gone), or from `eval_hnf`
(the C caller's locals are covered by C roots). In particular, a case
block's variables are in its frame while it waits for its scrutinee. This
is why frames are pushed eagerly (the lazy-frames experiment in
`explicit-stack-plan.md` would have broken this).

The check itself is one load, compare and branch at each entry:

```c
#define GC_SAFE_POINT(root, sp) \
    if (rice_heap_since_gc > rice_heap_threshold) root = gc_collect(root, sp)
```

`gc_collect` returns the moved `root`, and updates frames, the trail and
C roots in place. Generated code puts this first in every `_hnf`.
`ToH`/`ToC` change by one line.

------------------------------------------------------------------------------

Allocator
---------

- The heap is a list of **chunks** (start with 4 MB each), obtained with
  `calloc`, so they arrive zeroed. Code relies on fresh nodes having NULL
  children (`set_X` for partial applications, recursive `let`s,
  `CHECK_LAYOUT`).
- `alloc(size)` is an inline bump: `p = rice_heap_next; rice_heap_next += size;`.
  When that passes `rice_heap_limit`, a slow path takes a new chunk.
  Sizes are rounded to 8 bytes. Requests larger than a chunk get a
  dedicated chunk of their own.
- `rice_heap_since_gc` counts bytes, for the trigger. The existing `mem`
  allocation counter (printed by `nf_all`) keeps counting allocations, so
  the goldens' "total memory allocations" lines stay meaningful.
- Only nodes and nodes' spill arrays are heap objects. `bt_stack`'s
  `Stack` and its array move to `malloc` (they're runtime-owned, never
  shared), and so do the evaluation stack and C-side strings, which use
  `malloc` already.

Threshold: start at 64 MB. After each collection, set it to
`max(64 MB, 2 × live bytes)`, so collection costs stay proportional to
allocation.

------------------------------------------------------------------------------

Collector: Cheney copying, over chunks
--------------------------------------

1. Start a fresh to-space (a new chunk list).
2. Copy each root's target, then scan the copied objects breadth-first,
   copying everything they point to (Cheney's algorithm; the scan pointer
   walks the to-space chunks).
3. Free every from-space chunk.

**Copying a node** copies `sizeof(Node)`, and its spill array if it has
one. A moved node is overwritten with a GC forwarding marker: its
`symbol` becomes `&gc_moved_symbol`, and `children[0]` holds the new
address. That symbol is used by nothing else, so it can't be confused with
graph-level `FORWARD_TAG` nodes, which are ordinary nodes and copied as
such. The `epoch` field (`OPT_EPOCH_TRAIL`) is copied unchanged, so
allocation order is preserved.

**Tracing a node's children** (the rules from `node.h`):

| Node | Pointer children traced |
|---|---|
| ordinary constructor or function | slots `[0, filled_arity(n))` whose `child_rep` is `R_PTR` |
| partial application (`missing > 0`) | the same: `filled_arity` already excludes the empty slots |
| `apply` node (`missing < 0`, arity 0) | child 0 (the function), then arguments `1 .. -missing` (stored reversed, spilling past slot 3) |
| choice | children 0 and 1 (slot 2 is the raw `side`) |
| forward | child 0 |
| free variable, failure | none |

A NULL child is skipped: recursive-`let` placeholders, unfilled slots.

**Frames**: every slot whose `FrameInfo.reps` entry is `R_PTR`. Sentinel
frames have no slots.

**Trail entries** (`FieldPair`): `lhs` (the node to restore) and `rhs`
(a whole-node snapshot, or for `push_choice`/`push_frame`, a node). Both
are nodes, so both are traced, and the snapshots' own children are traced
like any node's.

------------------------------------------------------------------------------

C roots
-------

C code that holds node pointers in locals across a call that can run the
machine (and so reach a safe point) must register them:

```c
GC_ROOT(x);          // push &x on a root stack
...
GC_UNROOT(1);        // pop n
```

The root stack is a plain array of `union field*`. The known sites, all
C-convention code that evaluates through `eval_hnf`/`nf`/`settle`:

- `nf_all`, `run_io`: the program's root expression, across every
  `nf`/`undo` iteration;
- `strictApply` (`$!!`/`$##`): `root`, `f`, `x` across `settle(x, nf)`;
- `constrEq`: `root`, `x`, `y` across `nf(x)`, `nf(y)`;
- `toCStr`/`settleStringNode` (`prim_error`, `writeFile`, `appendFile`,
  `readFile`'s path, `read*Literal`): the string being walked;
- `prim_ioError`: `err` (it exits, but reads `err` after settling it);
- the C-convention wrappers' bodies, wherever they keep `root` across an
  evaluation.

Machine code needs no C roots: across an evaluation its state is in a
frame. The hazard is limited to C-convention code, and a debug mode
catches mistakes (below).

------------------------------------------------------------------------------

Debugging
---------

- **`-DGC_STRESS`**: collect at *every* safe point. A missing root then
  breaks almost immediately and deterministically. The whole test suite
  runs under it (`RICE_CFLAGS=-DGC_STRESS tests/run.sh`).
- **Poisoning**: under `GC_STRESS` or `DEBUG`, freed from-space chunks
  are filled with a byte pattern before `free`, so a stale pointer reads
  garbage that `CHECK_LAYOUT` and the tag dispatch reject loudly, instead
  of reading still-intact old data.
- `CHECK_LAYOUT` also checks every copied node during a collection.
- `--debug` prints collections (live bytes, time) at `LOW`.

------------------------------------------------------------------------------

Staging (each keeps the suite green)
------------------------------------

Status:

- **Stage 1 done 2026-10-09.** `runtime/heap.c` and an inline `alloc` in
  `memory.h`: 4 MB `calloc`'d chunks, bump allocation, and a dedicated
  chunk for any request over a quarter chunk. `bt_stack` uses
  `malloc`/`realloc`. Measured interleaved against `calloc`: **9–13%
  faster** (cent 0.450→0.391 s, primesort 1.080→0.981, reverse_builtin
  0.389→0.351, sort 1.526→1.337, tailsum 0.731→0.659). That puts Rice
  at or below its pre-evaluation-stack speed on four of the five, with
  tailsum still +14%.

  Found while planning stage 2: `save_snapshot`/`choose` `memcpy` whole
  nodes, so a node and its trail snapshot **share** its spill array. To
  keep that sharing, spill arrays get a one-word header (0 normally, the
  forwarding address once copied), allocated through one helper,
  `alloc_spill`.

- **Stage 2, 2026-10-09.** `runtime/gc.{h,c}`: a copying collector with
  an explicit work list rather than a linear Cheney scan. Spill arrays
  carry no type information, so the to-space can't be walked; each copied
  node is pushed, and each copied spill array is traced once, with its
  first owner's layout. `GC_SAFE_POINT(root, sp)` is the first statement
  of every `_hnf`: generated (`ToC.showBody`) and all 32 runtime entry
  points. C roots: `settle`, `settleStringNode`, `toCStr`, `strictApply`
  and the `$!!`/`$##` entries, `constrEq`, `prim_ioError`, the seven
  `toCStr` callers, `writeToFile`, `nf_all`, `run_io`, `machine_run`.
  From-space is poisoned with `0xAB` under `GC_STRESS` or `DEBUG`.

  Results: correct output, and much lower peak memory on the deep tests
  (`foldr (+) 0 [1..10^6]` 1.7 GB → 306 MB, `$!!` on a million elements
  1.6 GB → 469 MB, two million IO steps 2.5 GB → 442 MB; what remains is
  genuinely live, like a million pending frames). Under
  `RICE_CFLAGS=-DGC_STRESS tests/run.sh`, a collection at every safe point:
  56 pass and no crash or wrong output; 11 time out at 15 s (the five
  deep tests, and `fib`, `fib_det`, `half`, `queens_perm`, `schedule`,
  `sieve`, which run long when every function entry copies the heap).

  Normal threshold: full suite 67/67, slow 28/28, no-scoped-retry 37/37.
  Timing, interleaved, against stage 1 (bump allocation, no collection):
  cent −13%, primesort −22%, sort −21%, tailsum −11%, all *faster*, and
  peak memory drops (sort 6.5 GB → 78 MB, tailsum 2.4 GB → 78 MB). The
  exception is **reverse_builtin, +49%**: it builds a 4M-element list that
  stays live (663 MB at its last collection). Each of its four collections
  copies everything built so far, about 1.1 GB in total. That's a copying
  collector's worst case, a live set that keeps growing. Options for
  later: a larger growth factor than 2× (fewer collections, more memory),
  or generations. `-DGC_STATS` prints every collection's live size to
  stderr.

- **Stage 3, 2026-10-10.** `tests/run.sh` takes `-- rice-maxrss: N`
  (peak RSS in MB, via `/usr/bin/time`), and `tests/programs/gc/` has
  four memory-bounded tests. Writing them found two leaks:

  * **Forwarding chains (fixed).** A long IO loop kept every step alive:
    each step's bindIO node ends up forwarding to the next, and `run_io`
    roots the first, so the live set grew ~48 bytes per step (`io_loop`:
    927 MB, 234 MB live at the end). The collector now skips FORWARD
    nodes on heap-internal pointers (`trace_child`) when no reader can
    tell them from their target: not `nondet`, and not on the trail
    (`GC_TRAILED`, a bit in `Node`'s padding, set for the length of a
    collection). Roots keep pointing at the node itself, since their code
    may be about to rewrite it. `io_loop` now peaks at 78 MB (from 927 MB)
    and runs 34% faster (4.36 s -> 2.88 s, interleaved, best of 5). The
    five benchmarks are unchanged (within 1%).
  * **Trail retention (open; `gc/nondet_pending` is XFAIL).** Under a
    pending choice, a tail-recursive loop whose accumulator depends on
    the choice rewrites its root in place every iteration, and each
    rewrite is trailed. Every snapshot keeps that iteration's list cell
    and accumulator alive: 200k iterations peak at 824 MB. Treating the
    trail as weak (drop entries whose node is unreachable, to a fixed
    point through the snapshots) was tried and reverted: it dropped 6% of
    entries here and none anywhere else in the suite, at the cost of a
    hash over the trail per collection. Keeping only the *oldest* entry
    per node between two points where `undo` can stop is necessary but
    not enough: the oldest snapshot of the loop's root still points at
    the list's head, whose *current* contents (the first cons) keep the
    whole consumed list reachable. The design that works traces liveness
    per "view" (the heap after undoing each trail segment), drops dead
    entries, overwrites dead current contents, and compacts the trail:
    see `~/curry/papers/unif/proofs/LEAKS.md` (design, soundness argument,
    and model-level testing). It needs the collector to know every live
    trail height: a frame rep for trail heights (an `R_TRAIL` beside
    `R_INT`) in the bindIO/commit, `lu`, `nseq` and generated case-block
    frames (`SCOPED_SAVE_CUTOFF`), plus registration for C code that
    holds one across an evaluation.

  Results: full 70/70 (+1 XFAIL), slow 83/83, no-scoped-retry 37/37,
  `OPT_NONDET_TRAIL=0` regressions 37/37. Under `GC_STRESS` nothing
  crashes or prints wrong output; the same long tests time out as in
  stage 2, plus the `gc/` tests. Copies of those with inputs of a few
  thousand give correct output under `GC_STRESS`. Stress costs about 1 ms
  per safe point even with a tiny live set (a fresh zeroed chunk and a
  poisoned old one each time), so anything long times out there.

1. **Allocator only.** Chunked bump allocation replaces `calloc`; no
   collection yet. Move `bt_stack` to `malloc`. This alone should show the
   allocation-speed effect. Measure with the interleaved timer.
2. **Collector, stress-tested.** `gc_collect`, `gc_moved_symbol`, node
   and frame tracing, trail tracing, C roots, `GC_SAFE_POINT` at every
   `_hnf` entry. Bring the suite up under `GC_STRESS` first, then with
   the normal threshold.
3. **Memory tests.** Regression tests that would exhaust memory without
   collection (a long IO loop, a long fold), checked with a resident-size
   limit (`ulimit -v`, or `/usr/bin/time -l` in the test script).
4. **Clean up** the Boehm `#ifdef GC` path in `memory.h`, and the
   "allocations" counter if a byte count is more useful.

------------------------------------------------------------------------------

Open questions
--------------

- **Chunk size and threshold** are first guesses; tune them with the
  interleaved timer.
- **Safe points only at `_hnf` entries.** Is there any loop that runs
  unboundedly long without entering a function? The candidates are
  runtime routines that iterate (`nfx_k` visiting children, `lu_k`), and
  they enter functions whenever they evaluate. A loop over
  already-evaluated data (`=:=`'s work list, printing) allocates nothing
  significant. Worth confirming with a test that allocates heavily in one
  loop.
- **Large objects** (spill arrays of huge arity) are tiny in practice. A
  dedicated chunk per oversized request is enough.
- **Generational collection** would help programs with a large live set.
  Defer until measurements say so.
