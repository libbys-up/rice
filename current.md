# Current state (2026-10-28)

Work in progress: measuring and tuning the backtracking optimizations.
Branch `phase1-codegen-and-runtime`, nothing pushed. Newest first:

- `3916ca7`: #3 records its cutoff lazily; scaled-up bench programs.
- `62ecb1c`: the #2 tail-dispatch flag; old_rice, KiCS2 and PAKCS sets.
- `42c0fcd`: optbench with real forward chains and interleaved timing.
- `73fd88a`: the optimizations fixed per the proofs; path compression.

The previous contents of this file (the garbage collector, stage 6) are in
git history at `eddacd5`. Leak 2 there (the trail keeping snapshots alive,
`gc/nondet_pending` XFAIL) is still open. One thing in its plan changed:
step 1 lists `SCOPED_SAVE_CUTOFF` as where a case frame holds a trail
height. That macro is gone. The cutoff slot (`cutS` in `enterCase`) now
holds height + 1, or 0 while unmarked, so a height remap must leave 0
alone and remap `slot - 1`.

Suite on 2026-10-28, default flags, before the two commits that follow
`3916ca7`: 120 pass, 13 xfail, 0 fail (not rerun with all flags on).
Suites at `3916ca7`: `tests/run.sh` 119 pass, 13 xfail, 0 fail, both with
the default flags and with all flags on. `regressions/fieldrep_debug_print`
failed to compile once with an empty build log and passed on three reruns,
the same kind of transient failure copy_chain had once.

## The optimizations

| # | flag | default | verdict so far |
|---|---|---|---|
| 1 | `OPT_NONDET_TRAIL` | on | Big win almost everywhere; less clear on SearchMAC (see the barrier). |
| 2 | `OPT_TAIL_DISPATCH` | on | Little effect, never slower. |
| 3 | `OPT_SCOPED_BACKTRACK` | on | Big win on the FunPats programs. With the lazy cutoff, its fixed cost is gone. |
| 4 | `OPT_COPY_COLLAPSE` | off | Mostly redundant with path compression. Candidate to drop. |
| 5 | `OPT_EPOCH_TRAIL` | off | Net win since nodes went back to six words (2026-10-28 rerun below). Candidate to turn on. |
| 6 | `OPT_PATH_COMPRESS` | off | Useful; covers most of what #4 does. |
| – | `OPT_WRITE_BARRIER` | on iff #1 and #5 | Required for #1+#5 soundness. |

All flags on: `-DOPT_NONDET_TRAIL=1 -DOPT_SCOPED_BACKTRACK=1
-DOPT_COPY_COLLAPSE=1 -DOPT_EPOCH_TRAIL=1 -DOPT_PATH_COMPRESS=1
-DOPT_TAIL_DISPATCH=1`. Add `-DOPT_STATS=1` for event counts
(`runtime.h`'s `OptStats`, printed at exit).

The bench is `tests/optbench.sh` (header comment has usage). The report is
`tests/.optbench/report.md`. Sets use `tests/programs/scaled/<set>/` in
place of the original program when one exists.

## Done 2026-10-28: #5's fixed cost on deterministic programs

Most of it was the node size. `Node.missing` was an `int`, so with #5 on the
4-byte `epoch` pushed `symbol` to offset 16 and every node grew from 48 to 56
bytes. `missing` is `int16_t` now, nodes are 48 bytes with or without #5, and
`node.h` asserts it. All flags on, best of 7–9 runs:

| program | 56 bytes | 48 bytes | #5 off |
|---|---|---|---|
| ReverseBuiltin | 0.146 s | 0.110 s | 0.107 s |
| PrimesBuiltin | 3.308 s | 3.156 s | 3.177 s |
| `scaled/pakcs/mergesort_or` | 0.519 s | 0.481 s | 0.480 s |
| TakPeano | 1.094 s | 1.085 s | 1.076 s |

What's left is within noise on these four. The other suspects (stamping each
allocation, `rewrite_stamp`, the epoch compare in `needs_trail`) weren't
profiled separately.

Rerun of optbench (`--configs=all,-epoch,+nondet,+nondet+epoch,+epoch`,
report in `tests/.optbench-epoch/report.md`). What #5 adds on top of
everything else, `-epoch` → `all`:

| program | `-epoch` | `all` |
|---|---|---|
| fib | 0.656 s | 0.129 s |
| young_nodes | 0.414 s | 0.228 s |
| SearchKanMis | 0.682 s | 0.386 s |
| ExpVarFunPats | 0.306 s | 0.243 s |
| SearchSMM | 5.415 s | 5.198 s |
| reverse_builtin | 0.552 s | 0.580 s |
| QueensUser | 4.055 s | 4.116 s |
| SearchMAC | 0.313 s | 0.315 s |

Nothing else moves outside noise. The worst case is reverse_builtin at
+5%, so #5 (with the barrier, as `all` has it) looks safe to turn on by
default. Not done yet: it's a default change, so it wants a full suite run
with the new defaults first.

## Settled 2026-10-28: the SearchMAC write barrier

On SearchMAC (`scaled/kics2/SearchMAC`, goal 40 39) #1+#5 trails 4.25M
rewrites, against 0.82M for #5 alone, because the barrier stamps nodes old.
We've accepted this. Trailing only the rewrites that must be undone isn't
decidable, and the barrier was always an approximation; a better rule would
be original research (and need the proofs in `backtracking_proofs.md`,
"The write barrier", extended).

The pattern, minimal:

```curry
total :: [Int] -> Int
total = foldl (+) 0

main :: Int
main = c `seq` total (map (+ c) [1 .. 100000])
 where c = 0 ? 1
```

`map (+ c) [1..n]` is created before the choice and walked after it. Each
rewrite of the list is deterministic, so #1 doesn't trail it, and the barrier
stamps what it builds as old as the cell it came from, all the way down. Every
`x + c` reads the choice, so its rewrite must be trailed, and it's old, so #5
can't skip it: #1+#5 trails exactly what #1 alone does (1.0M), and #5 skips
nothing. #5 alone trails the first old cell instead, and everything built after
it is young (0.6M). A per-rewrite choice between the two (trail an old root
whose new value holds unevaluated calls) might keep #5's skips, but mixing the
rules is what the proofs would have to cover.

### Measured 2026-10-28: which stamped nodes cost anything

New `OPT_STATS` counters (`lowered_nodes`, `lowered_rewritten`,
`lowered_rewrites`, `lowered_trailed`; a stats-only bit in `gc_bits` marks a
node built with a lowered stamp). SearchMAC 40 39, all flags:

| counter | value |
|---|---|
| `barrier_lowered` (rewrites that lowered a stamp) | 14.15M |
| `lowered_nodes` (nodes built with a lowered stamp) | 7.62M |
| `lowered_rewritten` (of those, ever rewritten) | 5.51M (72%) |
| `lowered_rewrites` (rewrites of them) | 13.75M |
| `lowered_trailed` (of those, trailed) | 3.90M |
| `trailed_rewrites`, all | 4.25M (0.82M with #5 alone) |

So 92% of #1+#5's trail entries are rewrites of stamped nodes, and the extra
~3.4M snapshots are the extra ~3M allocations (18.3M vs 15.3M). Stamping only
nodes that are later rewritten wouldn't help: the 28% that never are cost
nothing already. The cost is thunks built under an old deterministic root
that are later evaluated after reading a choice. `lowered_trailed` is an upper
bound on what the barrier adds, since some of those nodes would be old
anyway. Reducing it needs a different sound rule, which means proof work.

## Proof work pending

- None. #3's lazy cutoff (`3916ca7`) is a reasonable extension of what's
  proved, not something the proofs need to cover.
- Path compression's retargets can be trailed before a case marks its
  cutoff; `~/curry/papers/unif/proofs/lazy_cutoff.md` covers why that's
  harmless.

## Bench notes

- Rice has no encapsulated search, so scaled programs print few answers.
  The scaled programs' goldens were checked against KiCS2. SearchMAC 40 39
  took 30 min under KiCS2. `mergesort_or` was checked in Python.
- A freshly linked binary's first run is about 0.25 s slow; optbench
  repeats runs, but a one-off timing should warm up first.
- Scratch timing helpers from 2026-10-27 (`try.sh`, `exp3/time.py`) were in
  the session scratchpad and are gone; optbench covers the same ground.

## Hazards

- Build rice with `PATH=$HOME/opt/kics2/bin:$PATH cypm install`. After a
  codegen or runtime-header change, also clear rice's caches
  (`clean_rice_caches` in `tests/lib.sh`, or `tests/run.sh` without
  `--no-clean`).
- Don't edit a test script while it runs: bash reads scripts as it goes,
  so the running copy dies or misbehaves.
- In the proofs repo, `vm_compute` over 400 seeds segfaults. Run chunks
  of about 25 seeds with `ulimit -s 65520`.

## Bootstrapping (2026-10-29)

rice1 exists: rice compiles `Rice.Main` (from `src/`, with `CURRYPATH`
set to `packageLoadPath` from `Rice.PackageConfig`), and the result
compiles a hello world that runs. Status and next steps are in
`src/bootstrap-plan.md`. Externals of library modules are in
`runtime/ext/<Module>.c` (developer's manual, "External functions").

## Distribution (2026-10-29)

Done:
- Rice's own `lib/` (KiCS2 3.5.0's, `__KICS2__` renamed `__RICE__`;
  `tools/sync-lib.sh`), and `Rice.Frontend` runs the front end itself.
- `RICEHOME` defaults to the package directory; output is quiet without
  `-v`; failures exit 1; objects are per flag set (`obj-<hash>/`).
- `frontend/` is a submodule pinned at curry-frontend v3.1.0 (not on
  Hackage past 2.0.0). The top-level `Makefile` builds it into `bin/` with
  Stack (or cabal), runs `cypm install`, and precompiles Prelude. CPM has
  no install hooks, so a bare `cypm install` can't build the front end;
  rice then falls back to the build system's front end. Its Prelude
  `.tfcy` is byte-identical to KiCS2's. Suite: 120 pass, 0 fail.

To do:
- `LICENSE` still says `<AUTHOR NAME>`.
- A Linux run, and CI.
- `rice --help`: separate the developer options.
- Untested: rice built with PAKCS.
- Bootstrapping: rice still needs a Curry system to build itself.

## Settled 2026-10-28: collector loose ends

- **Stage 4 cleanup.** The Boehm path was already gone (`eddacd5`).
  The allocations counter stays a node count; it's printed (on stderr)
  only when `RICE_ALLOC_STATS` is set.
- **`GC_STRESS` speed.** Each collection zeroed a fresh 4 MB chunk and
  poisoned every old one, about 1 ms per safe point. `heap.c` now uses
  64 KB chunks under `GC_STRESS`, which also takes the chunk slow path
  and the own-chunk path far more often. A 20k-element strict fold went
  from over 60 s to 1.2 s. The suite under `GC_STRESS`: 78 pass, 42 time
  out at 15 s, no wrong output. What's left is real copying work
  (`copy_node`, `gc_collect`) plus `madvise`/`memset`; recycling chunks
  would gain at most about 2×.
- **Safe points only at `_hnf` entries.** Audited rather than tested:
  every runtime loop that allocates (`toCurryString`, `unify_step`'s
  `save_copy`, `lu_k`'s narrowing via `set_free_constructor`) allocates
  in proportion to a structure or string that existed when it started,
  so heap growth between safe points is bounded by a constant times the
  live heap. A test couldn't fail.
- Still open: `reverse_builtin`'s copying cost (needs a larger growth
  factor or generations), threshold and chunk-size tuning, and Leak 2.

## Diagnosed 2026-10-28: `gc/strict_fold` is dictionary construction

About 1 µs per element. A profile is almost all
`_inst#Prelude.Integral#Prelude.Int#_LETn_hnf` and
`_inst#Prelude.Ord#Prelude.Int#_LETn_hnf`, plus `apply_k`. Nothing in
rice specializes dictionaries, so every overloaded call at a known type
(`even`, `<=` inside `enumFromTo`) applies the instance function to `()`
and builds the whole dictionary again: Integral's builds Enum, Real and
itself through 13 lifted lets before one method is selected. Options, in
order of effort: share instance dictionaries as CAFs (they take `()`
only so they aren't CAFs); or inline instance functions so that the
method selector becomes a case of a known constructor and the call goes
straight to `_impl#even#...`. The second is the usual fix and likely
the biggest single speedup for ordinary programs.

## Loose ends

- `=:<=`'s CHOICE handling: fixed in `62ecb1c`, with
  `regressions/lazy_unify_choice`.
- Dropped the "lazy frames experiment" stash (2026-10-08). It
  predates root/sp-as-arguments, and `src/explicit-stack-plan.md`
  records its numbers and why it wasn't adopted.
- `runtime-review.md` (root) stays untracked on purpose: personal notes
  from the 2026-10-24 runtime review.
