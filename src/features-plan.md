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
| Mutable references | `Data.IORef` | compile error |
| `unsafePerformIO` and term inspection | `System.IO.Unsafe` | compile error |
| Exceptions | `Prelude.catch` | runtime error |
| Encapsulated search | `Control.Search.Unsafe`, `.AllValues`, `.SearchTree`, `.SetFunctions` | compile error |
| Reading and showing any term | `ReadShowTerm` | runtime error (stub) |
| Commands over pipes | `System.IOExts` (`execCmd`, `connectToCommand`, ...) | runtime error (stub) |

Gaps in the language itself (all XFAIL in `tests/manifest.txt`):

| gap | tests |
|---|---|
| `(=:=)` normalizes both sides before unifying, so a goal like `xs ++ [x] =:= l` prints its answer and then searches forever | Last, RegExp, SearchQueens, SearchEmbed, SearchHorseman, First, horseman |
| A free variable can't be narrowed to an `Int` stored as a raw field | SearchGraph |
| A constructor can have at most 49 children (`child_at_k` stops there) | SatSolver |
| Only depth-first search, so infinite search spaces never return | BFSvsPar, NDNums (SKIP) |

------------------------------------------------------------------------------

Version 2.0: the small ones
---------------------------

1. **`Data.IORef`** (`runtime/ext/Data.IORef.c`). An `IORef` is an
   `external data` node with one pointer field, like `Handle`. `newIORef`
   allocates it, `prim_readIORef` returns the field, and `prim_writeIORef`
   overwrites it. The write goes through `gc_remember`, since an old ref
   can be pointed at a young value. It isn't trailed: an IO action's
   effects are committed (`bindIO`'s `pop_to`). (Check that KiCS2 and
   PAKCS agree under `--interactive`-style search.)
2. **`unsafePerformIO`** (`runtime/ext/System.IO.Unsafe.c`). Evaluate the
   action the way `run_io` does, then rewrite the call with its result.
   The term-inspection functions (`isVar`, `identicalVar`, `isGround`,
   `compareAnyTerm`, `showAnyTerm`, `readsAnyUnqualifiedTerm`,
   `showAnyExpression`) read the node graph without evaluating it, so
   they're short C functions too. `spawnConstraint` needs residuation
   (suspending on a free variable), which rice doesn't have; it stays
   unsupported, with an error that says so.
3. **More than 49 children.** Generate the accessors (or index the spill
   array directly) instead of stopping at `child_at_49`. A codegen and
   `runtime.h` change; SatSolver is the test.

------------------------------------------------------------------------------

Version 3.0
-----------

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
8. **`(=:=)` as real unification.** Unify lazily, binding free variables
   to constructors only as far as the other side has been evaluated,
   instead of normalizing both sides first. The largest item here: it
   changes `constrEq`, `lu_k` and how bindings are trailed, and it's what
   seven XFAIL tests are waiting for. Needs the same kind of design note
   and model check as the backtracking optimizations.
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

- `-p/--noprelude` and `-e/--external` are listed under `--help-dev` but
  aren't implemented. Remove them, or implement them.
- Three `old_rice/benchmarks` tests are XFAIL because the programs are
  stale (`import Integer`, signatures the modern front end rejects). Fix
  the programs, not rice.
