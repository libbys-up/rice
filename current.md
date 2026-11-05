# Current state: rice 2.0 (2026-11-05)

Rice 2.0 is tagged `v2.0.0` on branch `phase1-codegen-and-runtime`. Nothing
is pushed yet; the GitHub release and CI are the next steps (see below).

What 2.0 is:
- Self-hosting, with a fixpoint (`tests/bootstrap.sh --fixpoint`), and
  buildable from a release tarball with only `make` and a C compiler
  (`make seed`, `make -j from-seed`, `make install`; README).
- `Data.IORef`, `unsafePerformIO`, any number of constructor fields, and
  shared IO actions that run every time (src/features-plan.md).
- Backtracking optimizations #1, #2, #3, #5 on by default; #4 and path
  compression kept as flags, measured to make no difference
  (`src/results/optbench-2026-11-05.md`).
- Against KiCS2: 1.53x faster by geometric mean over 51 programs, up to
  477x on nondeterministic ones, 2.4x slower on deterministic ones
  (`src/results/kics2-comparison-2026-11-05.md`). The paper's numbers are
  these two files, and the commits they name.
- Suite: 138 pass, 0 fail, 11 xfail. Bootstrap: 165 files identical.

Next, before 3.0:
- Push the branch; run the "Front end binaries" workflow and add its
  checksums to `tools/frontend-checksums.txt`; `make seed` and publish
  `rice-2.0.0.tar.xz` as a GitHub release, which runs the Linux release
  check (`.github/workflows/`).

3.0 (src/features-plan.md has the details):
- Optimizations: strictness analysis, then the optimizer back on by
  default; dictionary specialization for the deterministic gap.
- Remove #4 and path compression from the runtime.
- Features: `catch`, encapsulated search and set functions, incremental
  `=:=`, narrowing raw `Int` fields, `ReadShowTerm`, pipes.
- `--interactive` with IO after a choice (the later-commit question in
  `~/curry/papers/unif/proofs/LEAKS.md`).
- A rice-native reader for the caches, with no `String` (and maybe a
  binary format); per-push CI (needs KiCS2 on the runner); a Windows port
  (LLP64, POSIX calls); an uncaught `error` prints the raw `prim_error`
  term after its message.

Everything below is from before 2.0.

# Before 2.0 (2026-10-28 and later)

Work then: measuring and tuning the backtracking optimizations.
Newest first:

- `3916ca7`: #3 records its cutoff lazily; scaled-up bench programs.
- `62ecb1c`: the #2 tail-dispatch flag; old_rice, KiCS2 and PAKCS sets.
- `42c0fcd`: optbench with real forward chains and interleaved timing.
- `73fd88a`: the optimizations fixed per the proofs; path compression.

The contents of this file before that (the garbage collector, stage 6) are
in git history at `eddacd5`.

## The optimizations

Final verdicts (2026-11-05, `src/results/optbench-2026-11-05.md`); the rest
of this section is the earlier measurements that led there.

| # | flag | default | verdict |
|---|---|---|---|
| 1 | `OPT_NONDET_TRAIL` | on | Essential: 4.3x alone over naive. |
| 2 | `OPT_TAIL_DISPATCH` | on | Small win: 4% on average, up to 27%, never meaningfully slower. |
| 3 | `OPT_SCOPED_BACKTRACK` | on | Essential for functional patterns: up to 494x. |
| 4 | `OPT_COPY_COLLAPSE` | off | No measurable effect. Remove in 3.0. |
| 5 | `OPT_EPOCH_TRAIL` | on (since 2026-11-05) | 9% on average with #1 on, up to 5.3x, at most 9% slower. |
| 6 | `OPT_PATH_COMPRESS` | off | No measurable effect. Remove in 3.0. |
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

## Toward 2.0 (2026-11-03)

- `Data.IORef`, `unsafePerformIO`, and constructors with any number of
  children (`CHILD_AT`) are in (src/features-plan.md, "Version 2.0").
- A shared IO action runs every time it's used: bindIO runs a fresh copy
  and points the bind node at the copy (developer's manual, "Shared
  actions"). Tests: `externals/{shared_io,ioref,unsafe_io}`, matching
  KiCS2. `lazy_readfile` peaks at 28 MB (was 100 MB).
- `Rice.Transform.MergeLets`, just before ICurry, merges `let` chains;
  ANF keeps them apart. SatSolver compiles in seconds (42 MB of C before).
  Generated C byte-identical to merging in ANF, for 30 files.
- The optimizer is off by default (`-O`/`--run-optimizer` turns it on):
  it helped only Tak (26%) on twenty KiCS2 benchmarks and tripled compile
  time. The Rice vs KiCS2 numbers below were taken with it on.
- The caches (`.rtfcy`, `.rfcy`) are in rw-data's compact format, and a
  `.rmode` file records whether the optimizer ran. Derived `read` of
  Prelude's `.rtfcy` under KiCS2 took 6 s and 3.3 GB, which was nearly
  all of a small program's compile. A warm compile now takes about 0.2 s
  and 126 MB; a cold one (compiling Prelude) 15 s and 2 GB.
- Open: `--interactive` with IO after a choice doesn't rerun the action's
  effects correctly on backtracking (features-plan.md, "Also").

## Collector and IO (2026-11-01)

- `readFile` is lazy (4 KB blocks, re-readable by offset), and
  `writeFile`/`appendFile` stream (`13f2e76`).
- The collector is generational (`5cc1a98`, gc-plan.md stage 7): nursery,
  survivor space, old generation; write barrier `gc_remember` in every
  rewrite; trail and stack watermarks. rice1 compiling hello world: 30 s,
  2.6 GB (was 43 s, 5.7 GB). Programs that keep everything they allocate
  are up to 1.8x slower than with the old collector, and fib and
  SearchKanMis about 1.7-2.5x (their trails keep everything alive).
- `-DGC_VERIFY` checks the barrier and the watermarks at every minor
  collection. Open: tuning the nursery size.
- Leak 2 is closed (gc-plan.md stage 8): each major collection compacts
  the trail, drops entries no view can restore, and overwrites nodes no
  view can read. `gc/nondet_pending` 645 MB to 47 MB, fib 2.7 GB to
  49 MB, SearchKanMis 201 MB to 57 MB. Open: whether a later bindIO
  commit can expose a version it dropped (stage 8, "Open question").

## Rice vs KiCS2 (2026-10-30)

Both compilers' default settings, best of 3, the KiCS2 and old_rice
benchmark sets (scaled versions where there are any):

- Nondeterministic programs: rice far ahead. ExpSimpFunPats 469x,
  SearchMAC 59x, cent 22x, Half 19x, fib 13x, PermSort 10x; SearchKanMis
  and SearchSMM time out (120 s) under KiCS2.
- Deterministic programs: KiCS2 2-8x ahead. Primes, PrimesBuiltin,
  Queens, QueensUser, ShareNonDet, primesort, queens_det about 6x; TakPeano
  3.7x; Tak, sieve, schedule about 2x.

Profiles of PrimesBuiltin and Queens are mostly type-class dispatch:
`apply_k`, instance dictionaries rebuilt on every call (the
`_inst#...#Int` LETs), and default methods (`/=` through `==`). Same
finding as gc/strict_fold. Old rice predates type classes, which is
likely why it used to win on these too.

rice1 (deterministic, string-heavy) is slow for that reason plus its live
heap: compiling hello world it collects 134 times and copies 59.6 GB,
with up to 1.5 GB live while reading the cached Prelude (96 bytes per
character of a string, readFile is eager, and the collector isn't
generational).

## Bootstrapping (2026-11-03)

Both goals of src/bootstrap-plan.md are met: the fixpoint test passes,
and `make seed` / `make from-seed` build rice from a release tarball with
only a C compiler and the front end. See the plan's 2026-11-03 status.

## Bootstrapping (2026-10-29)

Rice is self-hosting: `tests/bootstrap.sh` (the triple test) passes, with
rice1's generated C identical to rice0's for all 157 files. Status and next steps are in
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
- A Linux run, and CI.
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
  factor or generations), and threshold and chunk-size tuning.

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
