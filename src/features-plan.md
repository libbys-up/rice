Plan: the features rice doesn't support yet
=========================================

Written 2026-11-02. What a Curry program can use under KiCS2 or PAKCS but
not under rice, and how to add each. Most of it is for version 3.0;
"Version 2.0" below says which pieces are small enough to go in first.

------------------------------------------------------------------------------

What's missing
--------------

A program that imports a library module whose externals rice doesn't
implement fails at compile time, naming the missing functions. `catch`
compiles but stops the program when it runs.

| feature | modules | today |
|---|---|---|
| Term inspection (`isVar`, `showAnyTerm`, ...) | `System.IO.Unsafe` | runtime error |
| Exceptions | `Prelude.catch` | runtime error |
| Encapsulated search | `Control.Search.Unsafe`, `.AllValues`, `.SearchTree`, `.SetFunctions` | compile error |
| Reading and showing any term | `ReadShowTerm` | runtime error (stub) |
| Commands over pipes | `System.IOExts` (`execCmd`, `connectToCommand`, ...) | runtime error (stub) |

Gaps in the language itself (all XFAIL in `tests/manifest.txt`):

| gap | tests |
|---|---|
| `(=:=)` normalizes both sides before unifying, so a goal like `xs ++ [x] =:= l` prints its answer and then searches forever | Last, RegExp, SearchQueens, SearchEmbed, SearchHorseman, First, horseman |
| A free variable can't be narrowed to an `Int` stored as a raw field | SearchGraph |
| Only depth-first search, so infinite search spaces never return | BFSvsPar, NDNums (SKIP) |

------------------------------------------------------------------------------

Version 2.0: the small ones
---------------------------

Decided 2026-11-02: these three go in 2.0. Done 2026-11-03.

1. **`Data.IORef`** (`runtime/ext/Data.IORef.c`). A ref is a box node
   pointing at a cell node, and a write changes the cell, never the box:
   the box is an ordinary constructor node, which copy collapsing may
   duplicate, and every copy has to see the same writes. Writes go through
   `gc_remember` and aren't trailed, since bindIO commits to an action's
   effects. Test: `externals/ioref` (matches KiCS2, run under GC_STRESS).
2. **`unsafePerformIO`** (`runtime/ext/System.IO.Unsafe.c`). The call
   becomes `act >>= return`, so it runs the way any action does. The
   term-inspection functions still stop with "not yet implemented"
   (`lib/System/IO/Unsafe.curry`); `spawnConstraint` needs residuation,
   which rice doesn't have. Test: `externals/unsafe_io`.
3. **Any number of children.** `CHILD_AT(r, k)` (`runtime/macros.h`)
   indexes the spill array for k >= 3, replacing `child_at_0` to
   `child_at_49`. SatSolver compiles and runs.

Doing these turned up a bug in IO: running an action rewrites its node
with the result, so a shared action (`let p = putStrLn "hi" in p >> p`)
ran only once. bindIO now runs a fresh copy of the action each time, and
points the bind node at the copy so the original call (and its
arguments, like `writeFile`'s string) can be collected. Test:
`externals/shared_io`, which matches KiCS2.

------------------------------------------------------------------------------

Version 3.0
-----------

Rice 2.0 was tagged 2026-11-05 (current.md). Besides the items below, 3.0
removes #4 and path compression from the runtime (measured to make no
difference, `src/results/optbench-2026-11-05.md`), and turns the optimizer
back on by default once there's strictness analysis.

4. **Exceptions: `catch`.** `catch act h` pushes a handler frame holding
   `h`, the machine stack depth and the trail height, then runs `act`. An
   `IOError` (`ioError`, a failed IO primitive, which today exits through
   `ext_io_error`) unwinds the machine stack to the nearest handler frame,
   undoes the trail to its height, and runs `h err`. Because the machine
   keeps its whole state in frames, unwinding is popping frames: no
   `longjmp`. Also: an action that fails gives `FailError`, and one with
   more than one result gives `NondetError` (the Prelude's `IOError`
   constructors). Decide whether `error` itself becomes catchable; check
   what KiCS2 and PAKCS do.
5. **Encapsulated search.** Rice already has the pieces: `nf_all`'s
   search loop, and scoped `undo(cutoff)` (#3, and `lu_k`). `allValues e`
   records the trail height as a cutoff, evaluates `e` to normal form,
   *copies* each value out (the nodes it lives in are undone when the
   search backtracks), backtracks to the cutoff until there are no more
   values, and returns the list. `oneValue` stops at the first.
   `Control.Search.AllValues` and `rewriteAll`/`rewriteSome` follow.
   - This is strict, like PAKCS's `findall`: an infinite search space
     never returns, where KiCS2's lazy search tree can be explored
     partway. A lazy `someSearchTree` would need to suspend a search and
     resume it later, which a single trail can't do. So rice gets its own
     `Control.Search.SearchTree`, built on `allValues`, the way
     `replace/` overrides Prelude definitions.
   - **Set functions** need the arguments' nondeterminism kept outside
     the encapsulation: `set1 f x` evaluates `f x` inside the search, but
     a choice inside `x` belongs to the caller. KiCS2 tracks which
     choices belong to which depth (`incDepth`); look at how PAKCS does
     it too before choosing. For rice: give each choice the
     encapsulation depth it was made at, and when the search's undo
     reaches a choice from outside, stop and let the outer search take
     it. Needs a design note and a proof sketch before code; the model in
     `~/curry/papers/unif/proofs` is the place for it.
6. **`ReadShowTerm`.** `showTerm` and `readTerm` need a table from
   constructor names to symbols. Generate one per program in
   `rice-main.c` from the linked modules' constructors.
7. **Pipes in `System.IOExts`.** `execCmd` and `connectToCommand` with
   `fork`, `pipe` and `exec`, returning `Handle`s; the rest of
   `System.IO` then works on them unchanged.
8. **`(=:=)` as incremental unification.** `=:=` is strict: it succeeds
   only when both sides evaluate to unifiable data terms. (`=:<=`, for
   functional patterns, is the non-strict one.) But KiCS2 doesn't
   normalize first: `unifyTry` (`~/opt/kics2/runtime/Types.hs`) takes
   both sides to head normal form, compares the root constructors, and
   recurses on the arguments; binding a free variable forces the whole
   term it's bound to. So a mismatch fails at the first constructor that
   differs. Rice normalizes both sides first, so `xs ++ [x] =:= l`
   enumerates every `xs` before comparing anything. Doing it KiCS2's way
   changes `constrEq` and how bindings are trailed, and it's what seven
   XFAIL tests are waiting for. Check the Curry report's definition too,
   and write a design note before the code.
9. **Narrowing raw `Int` fields.** A free variable that has to become an
   `Int` stored unboxed. Either box the field when it holds a free
   variable, or keep a separate binding for it.
10. **Complete search strategies** (breadth-first, iterative deepening)
    for `nf_all`. Possibly; rice's trail is built for depth-first, and
    this may not be worth it.

Order within 3.0: 4 (catch) and 5 (encapsulated search) first, since
libraries depend on them. Then 8 (unification), the biggest semantic gap.
Then the rest as programs need them.

------------------------------------------------------------------------------

Also
----

- (2026-11-02) `=:=` is strict, not lazy; item 8 was first written as
  "unify lazily", which was wrong. The difference is the evaluation order.
- (2026-11-03) `--interactive` and IO after a choice: when nf_all
  backtracks to a choice made before an action ran, the action's effects
  don't run again correctly. bindIO's commit drops every trail entry made
  inside the action, including snapshots of nodes older than the choice,
  so those nodes keep their state from the first run.
  `gc/trail_commit`'s golden records this, and so does
  `let c = 0 ? 1; m = if c == 0 then putStrLn "zero" else putStrLn "one"
  in c `seq` (m >> m)`, whose second solution prints "one" once. It's the
  open question in `~/curry/papers/unif/proofs/LEAKS.md` about a later
  commit; KiCS2 rejects nondeterministic IO instead.
- (2026-11-03) The optimizer (`Rice.Optimize.Inline`) is off by default;
  `-O` turns it on. Bring it back as the default in 3.0, with strictness
  analysis, which it needs to pay off (developer's manual, "The
  optimizer").
- (2026-11-03) The caches are in rw-data's compact format. Once rice
  compiles itself, replace that with a reader that builds the terms
  straight from the file's bytes, with no `String` in between, and maybe a
  binary format.
- `-p/--noprelude` and `-e/--external` are listed under `--help-dev` but
  aren't implemented. Remove them, or implement them.
- Three `old_rice/benchmarks` tests are XFAIL because the programs are
  stale (`import Integer`, signatures the modern front end rejects). Fix
  the programs, not rice.
