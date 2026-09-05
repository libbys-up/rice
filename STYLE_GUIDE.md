# Rice Style Guide

This documents the conventions the working parts of Rice actually follow today,
plus concrete suggestions where the codebase is inconsistent with itself. It's
descriptive first (so new code fits in) and prescriptive second (so drift gets
cleaned up over time). It doesn't cover things the project hasn't decided yet —
see `STATUS.md` for open design questions (case-shortcutting, codegen ABI, etc).

The clearest reference for "good Rice style" right now is the pipeline that's
actually wired together and building: `Rice.Transform.*`, `Rice.Files.*`,
`Rice.Util`, `Rice.Main`. Everything below is drawn from those unless noted.

## Curry code

### Module naming

Modules are named with a dotted hierarchy that mirrors the directory path:
`Rice.Transform.ANF` lives at `src/Rice/Transform/ANF.curry`,
`Rice.Files.Info` at `src/Rice/Files/Info.curry`, etc. Keep doing this for any
new module.

**Inconsistency to fix:** the `Rice/Codegen/` subtree doesn't follow this —
`src/Rice/Codegen/CodeGen.curry:1` declares `module CodeGen where`,
`src/Rice/Codegen/Options.curry:1` declares `module CodeGen.Options where`,
`src/Rice/Codegen/C/C.curry:11` declares `module Codegen.C.C where` (lowercase
"g"), while its sibling `src/Rice/Codegen/C/ToC.curry:1` uses
`module Rice.CodeGen.C.ToC` (capital "G") and `ToH.curry:1` uses
`module Rice.Codegen.C.ToH` (lowercase "g") — three different casings of
"Codegen" in one directory. Pick one canonical form — `Rice.Codegen.*` (matches
the directory name on disk) — and rename all of them when this subtree gets
rewritten.

Similarly, `src/Rice/Data/Functional/DList.curry:2` and
`src/Rice/Data/Logic/DList.curry:1` both drop the `Rice.` prefix
(`module Data.Functional.DList`, `module Data.Logic.DList`). Restore it.

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
this holds across essentially all of `Rice.Util`, `Rice.Transform.*`. The one
exception is `run` in `src/Rice/Main.curry:28`, which has no signature.
**Suggestion:** give it one (`run :: [CompilerOptions] -> TProg -> IO ()`) to
match the rest of the codebase; it's a straightforward oversight, not a
deliberate style choice.

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
blank line between the groups, as in `src/Rice/Main.curry:3-16`. This isn't
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
`src/Rice/Codegen/CodeGen.txt` and `Scrutinee.txt`) out of the source tree —
see the Documentation section below.

### Data types

Plain sum types with positional constructors are the default, e.g.
`src/Rice/Main.curry:46-52`:
```
data CompilerOptions = SPrintFlatCurry | SPrintReplace | ...
 deriving (Show, Eq)
```
Reach for a record only when a type genuinely has several independent,
named config-style fields — the one example in the codebase,
`src/Rice/Codegen/Options.curry:22-30`'s `CompileOptions`, is exactly this
case. Don't default to records for ordinary ADTs.

`newtype` is for zero-cost single-field wrappers, e.g.
`newtype DList a = DList ([a] -> [a])` (`src/Rice/Data/Functional/DList.curry:8`).

### Error handling

Working modules avoid `error`/`undefined` for control flow. Failure is modeled
as `Maybe` (`isPrimCase :: [TBranchExpr] -> Maybe (TypeExpr, QName)`,
`src/Rice/Transform/Unbox.curry:129`) or as falling through to a sensible
default — e.g. `Rice.Files.Replace.replaceFunc` returns the original,
unmodified function if no replacement exists (`src/Rice/Files/Replace.curry:35-38`)
rather than erroring.

`error(...)` (Curry) / `error(msg, expr)` (the C runtime's helper,
`runtime/runtime.h:192`) is the right tool specifically for "this is
deliberately not implemented yet" — the C runtime uses it this way
consistently for unimplemented externals (`catch`, `failure`, `letrec`, etc.
in `runtime/external.c`). Keep using it that way rather than for ordinary
recoverable failure.

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

No `{-#`-style pragmas appear anywhere in `src/` — Curry's pragma surface is
smaller than GHC's, so there's nothing to enforce here beyond "don't add
pragmas without a reason." Custom `infixl`/`infixr` fixity declarations are
reserved for genuine DSLs, e.g. `src/Rice/Codegen/C/C.curry:35-42` for the
C-emission combinators. Don't declare fixity for ordinary project functions.

## C runtime code (`runtime/`)

- **Naming:** `snake_case` for functions/variables (`stack_push`, `make_choice`),
  `PascalCase` for types (`Node`, `Symbol`, `Stack`), `ALL_CAPS` for macros and
  constants (`FAIL_TAG`, `FUNCTION_TAG`, `NO_OPTS`).
- **Curry-facing name mangling:** generated/Curry-facing symbols follow a
  `Module_function_hnf` / `make_Module_function` / `set_Module_function` triple,
  with a fixed escape scheme for special characters (`_US` for `_`, `DL` for
  `$`, `EX` for `!`, etc.) — e.g. `Prelude__DL_EX_hnf` for `$!`
  (`runtime/external.c:294`). Keep new externals consistent with this scheme
  rather than inventing new escapes.
- **Formatting:** Allman brace style (opening brace on its own line), 4-space
  indentation, no tabs, anywhere in `runtime/*.c`/`*.h`.
- **Header guards:** classic `#ifndef X_H` / `#define X_H` / `#endif`, named
  after the file (`NODE_H`, `RUNTIME_H`, `MACROS_H`, ...). No `#pragma once`.
- **File organization:** one file per concern — `node.h` (representation),
  `stack.h`/`.c` (backtracking stack), `runtime.h`/`.c` (reduction engine),
  `macros.h`/`debug.h`/`memory.h` (small cross-cutting utilities). Keep new
  runtime code similarly separated rather than growing one of the big files
  further.
- **Memory:** pluggable at compile time via `-DGC` — either Boehm GC
  (`GC_MALLOC`) or a `calloc`+counter fallback (`runtime/memory.h:6-13`). Normal
  node-allocation paths never call `free()` manually; `runtime/stack.c:27-31`
  is the one place that does, and it's flagged as a bug in `STATUS.md`, not a
  pattern to imitate.
- **Error handling:** one central `error(msg, expr)` helper
  (`runtime/runtime.h:192`, defined `runtime.c:607-612`) that prints and exits.
  A few call sites bypass it with a raw `exit(0)`/`exit(1)`
  (`runtime/external.c:132-133,288-289,365-366`) — these are inconsistencies to
  clean up, not a second accepted pattern; route all fatal-error paths through
  `error(...)`.
- **Macros:** used deliberately for the `child_at_N` dispatch table
  (`runtime/macros.h`), for selecting optimization strategy via `-DTEST=N`
  (`runtime/runtime.h:61-99`), and for debug logging that compiles to nothing
  when `DEBUG` is unset (`runtime/debug.h`). Multi-statement macros should be
  wrapped in `do { ... } while(0)` — `runtime/memory.h:11`'s `alloc(size)`
  macro currently isn't, which is fragile; new macros should not repeat that.
- **Inlining:** node constructors/setters are `static inline
  __attribute__((always_inline))` throughout (`runtime/runtime.h:106-501`,
  all of `Prelude_external.h`) — this is a deliberate performance choice
  (zero-cost wrappers at every call site) and should be kept for any new
  primitive constructor.

## Housekeeping suggestions (repo-wide)

These aren't style rules so much as loose ends worth tidying when convenient
— none of them are applied by this document, they're flagged for later:

- Delete the stray root-level `Untype.curry` — it's an older, buggier draft of
  `src/Rice/Transform/Untype.curry` (wrong return type, doesn't recurse into
  `TLet`'s bound expression, missing imports) left behind by the rewrite
  commit.
- `LICENSE:1` still has the CPM template placeholder `Copyright (c) 2023,
  <AUTHOR NAME>` — fill in the real name.
- `test/a.out` (a compiled binary) is checked into the repo and isn't covered
  by `.gitignore` (`*~`, `.cpm`, `.curry` — see `.gitignore:1-3`). Either
  delete it or add a build-artifact ignore rule.
- `src/archetecture.md` has a typo'd filename (should be `architecture.md`)
  and is the only real design doc in the repo; `src/Rice/Codegen/CodeGen.txt`
  and `Scrutinee.txt` are informal first-person design/proof notes sitting
  next to source files. Consider consolidating all three into one
  `ARCHITECTURE.md` at some point, once the codegen design settles down.
- `runtime/external.c` and `runtime/Prelude_external.c` currently implement
  overlapping externals differently (e.g. `$!`, `returnIO`, file IO are real
  in `external.c` but stubbed with `error(...)` in `Prelude_external.c`), and
  both define `make_cstr` independently. When resuming work on externals,
  pick one file as canonical for each function rather than letting both grow
  independently — see `STATUS.md` for the itemized list.
- `runtime/external.c` uses a bare `field` type throughout, while everything
  else in `runtime/` uses `union field` — introducing a real `typedef union
  field field;` (or just rewriting `external.c` to say `union field`) would
  remove this split.
