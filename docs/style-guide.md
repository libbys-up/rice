# Rice Style Guide

This documents the conventions the working parts of Rice actually follow today,
plus concrete suggestions where the codebase is inconsistent with itself. It's
descriptive first (so new code fits in) and prescriptive second (so drift gets
cleaned up over time). It doesn't cover things the project hasn't decided yet —
see `docs/history/status-2026-09.md` for open design questions (case-shortcutting, codegen ABI, etc).

The clearest reference for "good Rice style" right now is the pipeline that's
actually wired together and building: `Rice.Transform.*`, `Rice.Files.*`,
`Rice.Util`, `Rice.Main`. Everything below is drawn from those unless noted.

## Curry code

### Module naming

Modules are named with a dotted hierarchy that mirrors the directory path:
`Rice.Transform.ANF` lives at `src/Rice/Transform/ANF.curry`,
`Rice.Files.Info` at `src/Rice/Files/Info.curry`, etc. Keep doing this for any
new module.

**Structural exception, not a violation:** `replace/replace_Prelude.curry` and
`replace/replace_Prim.curry` use flat, non-dotted, lowercase-led names
(`module replace_Prelude where`). This is required by the loader —
`src/Rice/Files/Replace.curry:63-65` loads `$RICEHOME/replace/replace_<module>.curry`
by that exact textual convention — so it's a structural necessity, not a style
lapse. Any new `replace_<Library>.curry` file should follow the same pattern.

### Identifiers

- Functions and variables: `camelCase` (`normalizeTExpr`, `replaceFuncs`,
  `showLoops`).
- Types and constructors: `PascalCase` (`TProg`, `CompileOptions`, `IProg`).
- Set-like list operators carry a `-`/`+` suffix borrowed from set algebra:
  `++-`, `\\-`, `&&-` (`src/Rice/Util.curry:39,49,59`), reused in
  `Rice.Transform.Order` and `ICurry.Goodies`. Follow this convention for any
  new "set-flavored" list combinator rather than inventing another name.
- The embedded C-emission DSL uses dot-prefixed infix operators mirroring C
  syntax (`.=`, `.==`, `.&&`, `src/Rice/Codegen/C/C.curry:45-91`) — keep this
  contained to that DSL, don't leak it into general Curry code.

### Type signatures

Every top-level binding gets an explicit signature, even trivial one-liners —
this holds across the whole compiler.

Untyped helper bindings inside `where`/`let` are fine and idiomatic (matches
Haskell/Curry convention generally).

### Imports

Use explicit import lists, e.g.
`src/Rice/Files/Replace.curry:6-8`:
```
import FlatCurry.Typed.Goodies (updQNamesInTProg, updQNamesInTFunc,
                                 updTProgTFuncs, tFuncName, tProgTFuncs,
                                 tProgName, updTRuleExtDecl, updTFuncTRule)
```
Group external-library imports above project-local (`Rice.*`) imports with a
blank line between the groups, as in `src/Rice/Main.curry:13-54`. This isn't
enforced everywhere yet — keep it in mind for new files.

`src/ICurry/Goodies.curry` used to import bare `Util`/`Sort` modules that
didn't exist under this project's own namespace — fixed 2026-08-29 when the
module was split into `ICurry.Goodies` (a fresh `FlatCurry.Goodies`-style
library of transform/selector/update/test functions for `ICurry.Types`) and
`ICurry.Transforms` (the old boxed-literal/case-analysis helpers, now
importing `Rice.Util` correctly). Both compile cleanly.

### Doc comments

Curry's CurryDoc convention (`--- ...` triple-dash) is the right style for
documenting exported functions — see `src/Rice/Util.curry:8`
(`--- get all variables...`) and the dense doc comments throughout
`FlatCurry/Typed/PrettyFixed.curry`.

**Inconsistency:** density varies a lot by file. `Rice.Transform.Unbox` and
`Rice.Transform.ANF` are heavily commented, including worked examples
(`src/Rice/Transform/Unbox.curry:21-52`) and even embedded LaTeX describing the
ANF transform (`src/Rice/Transform/ANF.curry:11-36`). `Rice.Transform.Order`,
`Rice.Transform.StrLit`, and `Rice.Codegen.Options` have little to none.
**Suggestion:** every exported function should get at least a one-line `---`
doc comment; save the worked-example/prose style for genuinely non-obvious
transforms (ANF, Unbox already do this well — keep that pattern for
similarly tricky code, don't feel obligated to add LaTeX to simple modules).

Long design-rationale prose (the kind in `Unbox`/`ANF`) is welcome inline when
it explains *why*, not just *what*. Keep pure scratch-reasoning (the kind in
`src/Rice/Codegen/CodeGen.txt` and `docs/history/scrutinee-notes.txt`) out of the source tree —
see the Documentation section below.

**Don't narrate bug-fix history in a comment.** See "Three kinds of comments"
below: history goes in a `.md` file, not in the code.

### Data types

Plain sum types with positional constructors are the default, e.g.
`src/Rice/Main.curry:317`:
```
data CompilerOptions
  = SPrintFlatCurry | SPrintFlatCurryRaw | ...
 deriving (Show, Eq)
```
Reach for a record only when a type genuinely has several independent,
named fields that are mostly used one at a time, like `FieldRepTable`
(`src/Rice/Codegen/FieldReps.curry:49`). Don't default to records for
ordinary ADTs.

`newtype` is for zero-cost single-field wrappers, e.g.
`newtype ReWriter a` (`src/FlatCurry/Transform/Typed/Utils.curry:76`).

### Pattern matching: flexible equations vs. rigid `case`

This is a Curry-semantics gotcha, not a Rice one, but it's easy to hit by
reflex if you're used to Haskell — worth knowing before it costs you a
debugging session. Curry's top-level function *equations* use **flexible**
matching: unlike Haskell, the language doesn't promise "commit to the first
equation whose pattern matches, top to bottom." Two equations can both be
considered live alternatives, explored non-deterministically, rather than
one strictly shadowing the other. This is harmless — and compiles to a
genuine, single, deterministic dispatch — when the patterns across
equations are disjoint constructors of the same type, covering it exactly:
`f [] = ...; f (x:xs) = ...`, `f True = ...; f False = ...`. But translate
Haskell's ordinary base-case/recursive-case idiom over an open-ended type
like `Int` straight across:

```
count :: Int -> [Int]
count 0 = []
count n = n : count (n - 1)
```

and it breaks: the second equation's bare variable pattern `n` matches
*any* argument, including `0`, so nothing ever commits to just the base
case. There is no finite set of constructors here for the compiler to
build an exhaustive dispatch over the way it can for `[]`/`(:)`, so this
gets compiled as an `Or` between the two equations' bodies, each guarded by
a check for whether its own pattern actually applies — and running it
doesn't stop at `0`, it keeps trying the second equation (whose guard never
fails) straight past it into negative numbers, forever.

**Fix**: reach for an explicit `case` instead of parallel equations
whenever a pattern isn't a disjoint, exhaustive constructor split — `case`
is **rigid**: it evaluates its scrutinee once and commits to exactly one
branch, the same as Haskell's own matching.

```
count :: Int -> [Int]
count n = case n of
  0 -> []
  _ -> n : count (n - 1)
```

Rule of thumb: parallel equations are fine exactly when every pattern is a
distinct constructor of one type and together they're exhaustive. The
moment a literal (`Int`/`Char`/`Float`), a guard, or a variable/`_`
catch-all is doing double duty alongside a more specific pattern for the
*same* function, use `case` instead.

### Error handling

Working modules avoid `error`/`undefined` for control flow. Failure is modeled
as `Maybe` (`isPrimCase :: [TBranchExpr] -> Maybe (TypeExpr, QName)`,
`src/Rice/Transform/Unbox.curry:129`) or as falling through to a sensible
default — e.g. `Rice.Files.Replace.replaceFunc` returns the original,
unmodified function if no replacement exists (`src/Rice/Files/Replace.curry:35-38`)
rather than erroring.

`error(...)` (Curry) / `error(msg, expr)` (the C runtime's helper,
declared in `runtime/runtime.h`, defined in `runtime/runtime.c`) is the right tool
specifically for "this is deliberately not implemented yet" — the C
runtime uses it this way consistently for unimplemented externals (`catch`,
`ensureNotFree`, `read*Literal`, file I/O, etc. in `runtime/ext/Prelude.c`).
Keep using it that way rather than for ordinary recoverable failure.

### No nondeterminism in rice's own code

Don't use `?`, free variables for search, or `Control.Search`/`findall` in
the compiler's implementation. Write deterministic code: `Maybe`, `Either`,
ordinary `case`. Rice is built with KiCS2, where any nondeterminism costs
choice-point machinery even on paths that turn out to be deterministic. The
optimizer's rewrite rules are the model: each rule returns a `Maybe`, and
`combine` tries them in order (`Rice.Optimize.Inline`, on
`FlatCurry.Transform.Typed.ExecDet`). Programs rice *compiles* can be as
nondeterministic as they like, of course; this is about rice itself.

### State-monad usage

Fresh-variable generation threads a `VarIndex` counter via
`Control.Monad.Trans.State`, with each module locally declaring
`type VState e = State VarIndex e`: see `src/Rice/Util.curry:83-86` (`fresh`),
`src/Rice/Transform/ANF.curry:38,47`, `src/Rice/Transform/Unbox.curry:54-56`.
**Suggestion:** since all three definitions are identical, factor `VState`
and `fresh` into one shared place (`Rice.Util` already has `fresh` — have
`ANF`/`Unbox` import it instead of redeclaring the type alias) so there's a
single source of truth for "how Rice generates fresh variables."

### Pragmas and fixity

The only `{-#` pragma in `src/` is `OPTIONS_FRONTEND -Wno-incomplete-patterns`
in `Rice.Build.TypedRW`, which follows the code `curry-rw-data` generates.
Curry's pragma surface is smaller than GHC's, so there's nothing to enforce
here beyond "don't add pragmas without a reason." Custom `infixl`/`infixr` fixity declarations are
reserved for genuine DSLs, e.g. `src/Rice/Codegen/C/C.curry:35-42` for the
C-emission combinators. Don't declare fixity for ordinary project functions.

## Three kinds of comments

This applies to every language in the project, not just C.

We write three kinds of comments, and each one has its own home.

1. **What this code does.** Comments on a function, a struct, or a tricky line,
   for someone reading that code. These stay in the code. They should be
   informative about anything surprising: an invariant the code depends on, a
   corner case, or a reason we didn't do the obvious thing. If a decision would
   make a new reader stop and ask "why?", answer it here.
2. **Architecture.** How the pieces fit together, and why the system is
   designed the way it is: the node representation, the evaluation machine, the
   trail, the garbage collector, the compiler's passes. These go in the
   developer's manual, `docs/developers-manual.tex`, which explains the whole
   design in one place for someone new to the project. A code comment can point
   to it in a line (or to a paper or web page for a general idea), but shouldn't
   repeat it.
3. **Process.** What we tried that didn't work, old bugs and how we found them,
   measurements, and things that are no longer true. These go in a `.md` file
   (`docs/history/runtime-history.md` for the runtime, `docs/history/compiler-history.md` for the
   compiler, or the plan document for the piece of work), where future sessions
   can find them. People reading the code
   don't need them, and they go stale as soon as the code changes again.

A quick test: if the comment would still be true and useful after the bug it
describes has been fixed for a year, it's kind 1 or 2. If it starts with "this
used to", "was tried", "confirmed by", or "before the fix", it's kind 3.

**Voice.** Write comments plainly, in the first person, the way you'd explain
the code to a student sitting next to you ("we", "I"). Short sentences. Say the
surprising part directly instead of piling on qualifications. Don't assume the
reader knows the history of the file.

## C runtime code (`runtime/`)

- **Naming:** `snake_case` for functions/variables (`trail_push`, `make_choice`),
  `PascalCase` for types (`Node`, `Symbol`, `Trail`), `ALL_CAPS` for macros and
  constants (`FAIL_TAG`, `FUNCTION_TAG`, `GC_MIN_THRESHOLD`). Prefix functions
  with the thing they work on (`trail_pop`, `frame_push`, `machine_run`) rather
  than using bare names like `pop` or `size`.
- **Curry-facing name mangling:** generated/Curry-facing symbols follow a
  `Module_function_hnf` / `make_Module_function` / `set_Module_function` triple,
  with a fixed escape scheme for special characters (`_US` for `_`, `DL` for
  `$`, `EX` for `!`, etc.) — e.g. `Prelude__DL_EX_hnf` for `$!`. Keep new
  externals consistent with this scheme rather than inventing new escapes.
- **Formatting:** Allman brace style (opening brace on its own line), 4-space
  indentation, no tabs, anywhere in `runtime/*.c`/`*.h`.
- **No space between a keyword and its parenthesis:** write `if(x)`,
  `while(x)`, `for(...)`, and `switch(x)`, not `if (x)`.
- **Always use braces** on `if`, `else`, `while` and `for` bodies, even for one
  statement.
- **Prefer `if` statements over the ternary operator.** Write

  ```c
  if(n.n->missing > 0)
  {
      return arity - n.n->missing;
  }
  return arity;
  ```

  rather than `return n.n->missing > 0 ? arity - n.n->missing : arity;`.
  The exception is a macro that has to be an expression; if you need one, ask
  whether a `static inline` function would do instead (that's why
  `child_at_v` and `set_child_at` are functions).
- **There's no `max` or `min`.** C has no standard integer `max`, and a
  hand-written `max(a - b, 0)` is wrong for unsigned values, because `a - b`
  wraps around to a huge number before `max` ever sees it. Compare first, then
  subtract, with an `if`:

  ```c
  if(arity > 3)
  {
      return arity - 3;
  }
  return 0;
  ```
- **One statement per line, and no one-line functions.** Don't write
  `static bool f(char c) { return ...; }` or
  `{ GC_SAFE_POINT(root, sp); rice_root = root; ...; RETURN(); }` on one line.
  Spread the body out, one statement per line, even when many functions have
  the same shape. If they really are all the same, say so once in a comment
  above them.
- **Prototypes:** declare a function with no parameters as `f(void)`, not `f()`.
  Under `-std=c11`, `f()` means "unspecified parameters", and the compiler won't
  check calls to it.
- **Unused parameters:** machine code has to take `(root, sp)` even when it
  doesn't use `root`. Name the parameter `_root` and write `(void)_root;` to
  silence `-Wunused-parameter`.
- **Header guards:** classic `#ifndef X_H` / `#define X_H` / `#endif // X_H`,
  named after the file (`NODE_H`, `RUNTIME_H`, `TRAIL_H`, ...). Label every
  closing `#endif` with what it closes. No `#pragma once`.
- **File organization:** one file per concern — `node.h` (representation),
  `trail.h`/`.c` (the trail), `machine.h`/`.c` (the evaluation machine),
  `memory.h`/`heap.c` (allocation), `gc.h`/`.c` (the collector),
  `runtime.h`/`.c` (the reduction engine), `ext/Prelude.c` (Prelude externals),
  `opts.h` (the compile-time flags and their defaults; `node.h` includes it
  first, since the node layout depends on them), `macros.h`/`debug.h`/`prim.h`
  (small cross-cutting utilities). Keep new
  runtime code similarly separated rather than growing one of the big files
  further.
- **Memory:** nodes and spill arrays come from `alloc` (`memory.h`), which
  returns zeroed memory from the garbage collected heap. Everything else (the
  trail, the machine stack, C strings) uses `malloc`/`free`. Never `free` a
  node.
- **Changing a node that already exists.** Nearly every bug in the runtime
  so far has been one of these three steps left out. When you rewrite a
  node in place, or change one of its children:
  1. **Trail it** if a choice could undo the change: call `trail_node(root,
     nondet)` before you write, with `nondet` covering everything you read
     to get the new value. It decides whether an entry is needed (#1 and
     #5). Choice points and free-variable bindings always trail
     (`push_choice`, `save_copy`).
  2. **Tell the collector** with `gc_remember(node)` (`gc.h`), the write
     barrier: the node may be old and the new child young. The `set_X`
     functions do this for you; a direct `child_at(...) = ...` doesn't.
  3. **Keep pointers rooted** across anything that runs the machine
     (`ext_hnf`, `settle`, `nf`, `toCStr`): those can collect and move
     nodes. Put local `field`s in a `GC_ROOT` first, and `GC_UNROOT` them
     after. Machine code keeps its state in frame slots instead, which the
     collector updates.
  The IORef cell write (`runtime/ext/Data.IORef.c`) and bindIO's repoint
  (`bind_k`, `runtime/ext/Prelude.c`) are short examples of all three.
- **Frame layouts:** put a comment with the slot layout,
  `[root, m, nondet, cutoff]`, next to every `FrameInfo`, hand-written or
  generated, so a reader can match `SLOT(i)` to its meaning.
- **Named constants:** give every magic number a name and a comment
  saying where it comes from, and whether it's measured or a first guess
  (`CHUNK_BYTES`, `GC_MIN_THRESHOLD`, `MAX_FORWARD_CHAIN`).
- **Word size:** rice targets 64-bit (LP64) platforms only. A pointer, a
  `long` and a `double` are each one 8-byte `union field` (`node.h`
  asserts it). Put any new assumption about sizes in a `_Static_assert`
  with a message that says what depends on it.
- **Vocabulary:** say "the trail" and "trail entry" (an entry is a saved
  node, or a choice-point marker), never "backtracking stack". A "frame"
  is only a machine-stack `Frame` (`machine.h`). "FORWARD node" for an
  indirection; "collapse" for turning a node into its result or a forward.
- **Error handling:** one central `error(msg, expr)` helper (`runtime.c`) that
  prints and exits. `runtime/ext/Prelude.c` routes every fatal path, real and
  stubbed, through it. Check the result of `malloc`/`realloc` in runtime data
  structures.
- **Macros:** used deliberately for `CHILD_AT`, which hides the spill
  array (`runtime/macros.h`), for the backtracking optimization flags
  (`OPT_*`, `runtime/runtime.h`), and for debug logging that compiles to
  nothing when `DEBUG` is unset (`runtime/debug.h`). Wrap multi-statement
  macros in `do { ... } while(0)`, with the `if` inside the loop and no
  trailing semicolon. The exception is a macro that has to `continue` or
  `break` out of the caller's loop (`SCOPED_RETRY`), since inside a do-while
  those would only leave the do-while; end that one with `else ((void)0)`
  instead, and say why in a comment.
- **Inlining:** node constructors/setters are `static inline
  __attribute__((always_inline))` throughout `runtime/runtime.h`
  — this is a deliberate performance choice (zero-cost wrappers at every
  call site) and should be kept for any new primitive constructor.

## Tests

- A runtime feature gets a test in `tests/programs/`, in the directory for
  its area (`gc/`, `externals/`, `regressions/`, ...), with a header
  comment saying what it checks and why. If it touches the heap, run it
  under `-- rice-flags: --cflags=-DGC_STRESS` too.
- Check a golden (`.expected`) before recording it: against KiCS2 (or
  PAKCS), or, if neither can run it, against an independent check, and say
  which in the test's header (`kics2_bench/SatSolver.curry`). Never record
  rice's own output just because it's what rice prints.
- A test that guards memory use says so with `-- rice-maxrss: <MB>`.
- Run `tests/run.sh` before every commit, and `tests/bootstrap.sh` before
  any commit that changes code generation or the runtime. Don't run two
  memory-heavy jobs at once (a suite, a bootstrap, a KiCS2 benchmark).

## Housekeeping suggestions (repo-wide)

These aren't style rules so much as loose ends worth tidying when convenient
— none of them are applied by this document, they're flagged for later:

- ~~Delete the stray root-level `Untype.curry`~~ — resolved: it's gone.
- ~~`LICENSE:1` still has the CPM template placeholder~~ — resolved
  (2026-11-02): `Copyright (c) 2023, Steven Libby`.
- ~~`test/a.out` is checked into the repo~~ — resolved: it's ignored
  (`.gitignore`) and no longer tracked.
- ~~`src/archetecture.md` has a typo'd filename~~ — resolved (2026-10-27): it
  and `src/architecture.tex` are replaced by `docs/developers-manual.tex`, with
  the case shortcutting design moved to `docs/plans/case-shortcutting-plan.md`.
  `docs/history/codegen-notes.txt` and `docs/history/scrutinee-notes.txt` are still informal
  design notes sitting next to source files.
- ~~`runtime/external.c` and `runtime/Prelude_external.c` currently implement
  overlapping externals differently~~ — resolved (2026-09-04): both deleted,
  superseded by the single `runtime/ext/Prelude.c` (see `docs/history/status-2026-09.md`'s Phase 2).
