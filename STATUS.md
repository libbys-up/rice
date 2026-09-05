# Rice Project Status

A working/incomplete/not-started/broken breakdown of every component, organized
by pipeline stage. This is a snapshot as of 2026-09-04, meant as a backlog for
planning next work — it doesn't prioritize or sequence anything, just records
what's true right now. The 2026-08-29 snapshot below this line covered the
compiler pipeline through ICurry generation for a single file; everything in
the multi-module driver, the optimizer, and the typed rewrite-engine layer
below is new since then and has been validated by actually running it (real
edit → recompile → re-run cycles under kics2 on the real Prelude, not just
compiling it), not just read for plausibility. The `runtime/`/Codegen section
was re-read and re-scoped on 2026-09-02, reviewed for simplification and
maintainability on 2026-09-03 (`src/codegen-runtime-review.md`), Phase 0
done and verified running that same day, and **Phase 1 — the actual
ICurry→C codegen, wired end to end into a real, running executable — done
and verified on 2026-09-04**: the entire pipeline now takes real Curry
source to a compiled, correctly-running binary, confirmed by actually
building and running three programs (one cross-checked byte-for-byte
against kics2's own output), not by reading generated C and assuming it
works. See Phase 1's own section below for the full account, including
several real runtime bugs (not codegen bugs) this pass's testing found —
core backtracking machinery (`undo`) that Phase 0's own smoke test never
had a reason to exercise. **Also on 2026-09-04, before committing Phase 1:
ran old_rice's own 35-program benchmark/test suite through the finished
compiler** (a functional verification pass, not benchmarking performance —
see Phase 1's own "Verification pass" subsection), which found and fixed
one more significant bug (`apply_hnf`'s fill-index math hadn't been
updated for `ToH`'s forward-storage change, silently corrupting any
partial application with 2+ arguments still missing — the same bug behind
`[a..b]` range syntax hanging outright) plus two missing `Prelude`
externals and a missing `-O2` that was silently limiting how deep a
tail-recursive Curry function could actually recurse.

Legend: 🟢 Working · 🟡 Incomplete · ⚪ Not started · 🔴 Broken

## Pipeline overview

```
source.curry (any module, resolved via CURRYPATH)
   │  readTypedFlatCurry (external: flatcurry-typed frontend;
   │  own staleness check against .curry)
   ▼
TypedFlatCurry (TProg) ─────────────┐
   │                                │  Rice.Build.Deps: module graph +
   │                                │  topological sort              🟢
   ▼                                │
Rice.Build.Cache: skip if the       │
optimized-TProg cache for this      │
module is up to date, else:         │
   │  condenseStrings   Rice.Transform.StrLit          🟢
   │  unbox             Rice.Transform.Unbox            🟢
   │  replacePrim/      Rice.Files.Replace              🟢 (mechanism)
   │    replace                                          / 🟡 (content)
   │  orderFuns         Rice.Transform.Order             🟢
   │  optimizeProg      Rice.Optimize.{FunTable,Inline}  🟢
   │  (cache the result)  Rice.Build.Cache               🟢
   ▼
   │  normalize (full ANF)  Rice.Transform.ANF           🟢
   │  removeTypes           Rice.Transform.Untype        🟢
   ▼                                │  driver threads FunTable + each
FlatCurry (Prog) ────────────────────  module's Prog forward through the
   │                                │  fold, in dependency order      🟢
   │  (external: icurry package,
   │   flatCurry2ICurryWithProgs)
   ▼
ICurry (IProg)
   │  ToC / ToH             Rice.Codegen.C.*             🟢 verified running
   ▼
C source  ──(Rice.Main shells out to gcc/clang)──►  linked against
                                        runtime/'s buildable core (🟢) +
                                        runtime/prelude_min.c (🟡, new) ──►
                                        a real executable, run and checked
                                        against kics2's own output  🟢
                                        (external.c/Prelude_external.*
                                        still 🔴/Phase 2)
```

`Rice.Main.curry` is the real multi-module driver now (not a single-file
compiler): it builds the whole module graph reachable from the module named
on the command line, topologically sorts it, and folds over it compiling
each module (or skipping it, if its cache is current) in dependency order,
threading both the accumulated cross-module inline table and each module's
`Prog` forward. The pipeline still stops at ICurry generation — nothing
downstream of ICurry is wired up, same as before.

## `src/` — compiler

### Multi-module driver, optimizer, and typed rewrite engine (new since 2026-08-29)

| Component | Status | Notes |
|---|---|---|
| `FlatCurry.Transform.Typed.Types`/`Utils`/`Goodies`/`ExecDet` | 🟢 | A deterministic `TExpr` rewrite engine — the typed counterpart of the (now real, `>= 0.0.2` in `package.json`) `flatcurry-transform` dependency's own `Types`/`Utils`/`ExecDet`, plus a `Goodies` module (`ground`/`sub`/`rename`/`strict`/`hasVar`/`uses`/`freeVarsOf`/etc.) covering what that package's `Utils` used to before an upstream refactor trimmed it down. Deliberately deterministic (`Maybe`-based `TExprTransformationDet`, not `?`/`Control.Findall`) — kics2 has real overhead for nondeterminism even on code that's deterministic in practice, so this was a design constraint, not an afterthought. Lives under `FlatCurry/Transform/Typed/` (mirroring `flatcurry-typed`'s own naming relative to `flatcurry`) specifically so it can migrate into the `flatcurry-transform` package directly if it works out. One correctness fix made while porting from old_rice: `recursive`'s `Case` clause used `&&` where every other clause is `any`/`\|\|`-shaped — looked like a transcription bug, fixed to `\|\|`. `ground` is deliberately *not* the same thing as `FlatCurry.Typed.Goodies.isGround` (that one excludes bare variables; this one needs them included, since substituting a variable reference can't duplicate anything) — documented in the code so nobody "fixes" it into the wrong function later. |
| `Rice.Optimize.FunTable` | 🟢 | Per-function facts (size, params, body, loop-breaker status) the optimizer consults, ported from old_rice's `Optimize/FunTable.curry` onto `TFuncDecl`/`TExpr`. `inlinable`/`simple` are the two gates (not external, not a loop breaker, under a 35-node size cap; `simple` additionally requires no internal `Case` and a smaller cap, for very cheap functions like `id`). |
| `Rice.Optimize.Inline` | 🟢 | The actual inliner: `inline` (cancels the constructor/literal/`Case` `Let`-bindings `normalizeLimited` was meant to leave inline — see the gap noted below), `caseCancel` (case-of-known-constructor/literal), `deadCode`, `reduce` (inlines any fully-saturated call to an `inlinable` function). `subGrounded`/`inlineCall` are the load-bearing correctness mechanism: a ground argument (variable, literal, or ground constructor application) substitutes directly, everything else gets exactly one `Let`, so nothing shared or non-deterministic is ever duplicated — this is what makes inlining safe regardless of what ANF stage the expression is in. |
| `Rice.Transform.Order` | 🟢 | `orderFuns`/`sccSort`/`inlineScore`: real per-cycle loop-breaker selection, ported from old_rice's `Optimize/LoopBreakers.curry`. Repeatedly removes the highest-`inlineScore` (priciest) member of each recursive group and recomputes SCCs on what's left, so only that one function per cycle is excluded from inlining rather than the whole group. Still has `loops`/`edges`/`calls` for `--printloops`. Known, narrow, pre-existing limitation carried over from before this session: `calls`'s call-graph edges are built from unqualified names only, so two same-named functions in different modules could theoretically get conflated — noted, not fixed. |
| `Rice.Build.Deps` | 🟢 | `buildModuleGraph`/`topoSort`: walks `tProgImports` from a root module (via `readTypedFlatCurry`, so module resolution and `.tfcy` freshness are already handled) and orders the result via `Data.SCC.scc` — empirically confirmed dependency-first before relying on it. `Left` on a cyclic import (Curry doesn't allow them; always a hard error). |
| `Rice.Build.Cache` | 🟢 | `needsRecompile`/`readCachedOpt`/`writeOptIfChanged`: mtime staleness for Rice's own persisted, optimized `TProg`, matching kics2's `CurryBuilder.smake` — stale if missing, older than the module's own `.tfcy`, or older than any import's cache (propagates transitively the same way kics2's does, since an import's cache mtime only advances when its content actually changed). Cache lives at `.curry/rice-1.0.0/`, deliberately *not* through `System.CurryPath.inCurrySubdir` directly (that reports whichever compiler is actually running Rice — kics2 — not Rice's own identity; using it directly silently dumped Rice's cache into kics2's own cache namespace, a real bug caught by checking where files actually landed after a run, not by re-reading the code). Verified through real edit → recompile → re-run cycles, which also caught a second real bug: `writeOptIfChanged`'s lazy `readFile` compared with `==` (which short-circuits at the first difference) left a read handle open, causing `withFile: resource busy` on the immediately-following write — fixed by forcing full evaluation first. Honest caveat: doesn't touch the frontend-level `.tfcy` parse or ICurry-generation cost, which dominate wall-clock time; the optimize stage it actually caches was already sub-millisecond per function under kics2, so there's no dramatic visible speedup yet — this is infrastructure for when the optimizer grows more expensive, not a performance fix today. |
| `Rice.Main` (driver, CLI options) | 🟢 | See pipeline overview above. CLI flags for C output (`-c`, `-e`/`--external`, `-x`/`--gcc`) still exist but nothing implements them yet. |

**Validated end-to-end**, not just compiled: the real Prelude (1268 functions after typeclass-dictionary desugaring) runs through the whole pipeline correctly under kics2 — read, 141 loop breakers computed, every function optimized, ICurry generated, in a few seconds. A second (non-Prelude) module compiling alongside it also works — this surfaced and fixed a real, previously-unexercised gap: `flatCurry2ICurry` (which always passes `impprogs = []`) re-reads an imported module's *original* frontend-generated interface from disk, which has no idea about Rice's own in-memory-only boxed-type declarations for `Prelude.Int`/`Char`/`Float` (added by `unbox`, only when compiling Prelude itself) — switched to `flatCurry2ICurryWithProgs`, threading each already-compiled module's `Prog` forward through the driver's fold, the same pattern already used for `FunTable`.

**Known design gap, not yet built:** `normalizeLimited` (a "limited" ANF pass — outlining calls/case scrutinees but not constructors/literals — meant to run immediately before optimization, giving `inline`'s `Let`-cancellation rules something to fire on) doesn't exist. The optimizer currently runs directly on `replace`'s output, before any ANF conversion at all. Still correct (see `subGrounded` above), just not as effective as the original two-phase design intended — `reduce`/`caseCancel`/`deadCode` are doing most of the real work right now. No constant folding either (e.g. `21 + 21` stays a runtime computation rather than folding to `42` at compile time) — old_rice had this (`Optimize/Primitives.curry`), not ported.

**PAKCS is impractically slow at real-Prelude scale** — reading the ~2MB real `Prelude.tfcy` via PAKCS's `read`-based term parser didn't finish in 5+ minutes. kics2 isn't just preferred for building/running Rice, it's required in practice for anything beyond toy input.

### Everything else (unchanged since 2026-08-29)

| Component | Status | Notes |
|---|---|---|
| `Rice.Util` | 🟢 | Utility library (`++-`/`\\-`/`&&-`, `fresh`, `newVar`, `vars`). |
| `Rice.Files.Info` | 🟢 | Debug-printing helpers. |
| `Rice.Files.Replace` | 🟢 | The replace-merge mechanism itself (loads `replace_*.curry`, splices functions into the real module's AST) works as designed. |
| `Rice.Transform.StrLit` | 🟢 | Condenses `Char` cons-lists into string literals. |
| `Rice.Transform.Unbox` | 🟢 | Box/unbox pass for Int/Char/Float; heavily documented. Only adds the synthetic boxed-type declarations when compiling Prelude itself (`tProgName p == "Prelude"`) — by design, but it's the reason `flatCurry2ICurryWithProgs` (above) is now load-bearing for any other module. |
| `Rice.Transform.ANF` | 🟢 | Full A-normal-form transform (`normalize`) — the "second phase" of the two-phase ANF design; the "first phase" (`normalizeLimited`) is the known gap noted above. |
| `Rice.Transform.Untype` | 🟢 | Strips TypedFlatCurry → FlatCurry. |
| `FlatCurry.Typed.PrettyFixed` | 🟢 | Adapted from Kai-Oliver Prott's pretty-printer; working. Also now used by `FlatCurry.Transform.Typed.ExecDet`'s debug-trace output — worth knowing about if this ever migrates alongside the typed rewrite engine, since upstream `flatcurry-typed` has no expression-level pretty-printer of its own. |
| `ICurry.Goodies` | 🟢 | `FlatCurry.Goodies`-style library of transform/selector/update/test functions for `ICurry.Types`. |
| `ICurry.Transforms` | 🟢 | Domain-specific ICurry helpers (boxed-literal case helpers, `varsInStmt`/`varsInExpr`/`varsInBlock`, etc.); `ToC.curry`/`ToH.curry` import this. |
| `Rice.Data.Functional.DList` | ⚪ | Plausible small `newtype` difference-list; still not referenced by anything in the working pipeline. |
| `Rice.Data.Logic.DList` | 🔴 | Variable-shadowing bugs in `(<:)`/`(++>)`; also unused. |
| `Rice.Codegen.C.{C,ToC,ToH}`, `Rice.Codegen.C.PrimOps` | 🟢 | Phase 1 (below): a working ICurry→C codegen, wired into `Rice.Main`, verified by actually compiling and running real programs. |
| `Rice.Codegen.Names` | 🟢 | Module header fixed to match its own path (was `CodeGen.Names`); `isStrConst`/`mangleChar` bugs fixed (Phase 1, below). |
| `Rice.Codegen.CodeGen`/`Options` | 🔴 (dead) | Turned out unneeded — Phase 1's port didn't reference either. Still present, still don't compile, still not part of the build; candidates for deletion, not fixing. |
| Root-level `Untype.curry` (untracked, outside `src/`) | 🔴 (dead) | Older, buggier draft of `Rice.Transform.Untype`; not part of the build; should be deleted. |

**Bottom line for `src/`:** the full pipeline — multi-module driver,
optimizer, staleness cache, and now the ICurry→C codegen through to a
linked, running executable — works, and has been run and cross-checked
against kics2's own output, not just compiled. `Rice.Codegen.CodeGen`/
`Options`, `Rice.Data.Logic.DList`, and `Rice.Data.Functional.DList` remain
genuinely dead/unused code, not part of the working path.

## `replace/` — Prelude rewrite

Unchanged since 2026-08-29. `Rice.Files.Replace` merges the small number of
functions defined in `replace_Prelude.curry`/`replace_Prim.curry` into the
real, full reference `Prelude.curry` — only when compiling the module named
`"Prelude"`. Everything not overridden passes through untouched and still has
to survive the rest of the pipeline unmodified.

| Component | Status | Notes |
|---|---|---|
| Equality/ordering, literal show, arithmetic, transcendental functions, `ord`/`putChar` | 🟢 | Correct (`replace_Prim.curry`). |
| `chr` | 🟡 | Present, but the reference's range-clamping is asserted (comment only) to now happen inside the C primitive `prim_chr` — unconfirmed. |
| `read*Literal` | ⚪ | No overrides exist at all, unlike their `show*Literal` counterparts. |
| `(=:=)`, `(=:<=)`, `constrEq`, `nonstrictEq`, `ioError` | 🟢 | Match the reference's own `__PAKCS__` branch. |
| `(=:<<=)` | ⚪ (by design) | Verbatim copy of the reference's own unsupported fallback. |
| `aValueInt`/`aValueNat` | 🟢 | Simplified narrowing value-generators. |
| `aValueFloat`/`aValuePosFloat` | ⚪ | A draft replacement exists but is commented out — abandoned mid-attempt. |

**Bottom line for `replace/`:** the bounded set of primitives it targets is
done and correct, with two remaining gaps (`read*Literal`,
`aValueFloat`/`aValuePosFloat`).

## `test/`

Unchanged since 2026-08-29 — still no test framework, no CurryCheck/EasyCheck,
no regression coverage for anything. `test/anfTest.curry` is two manually-
inspected example expressions; `test/test.c`/`test/a.out` is a scratch C
program for `div`/`mod`/`quot`/`rem` sign semantics, not a test of Rice
itself.

## `runtime/` and Codegen — scoped for 2026-09-02

Re-read directly this pass (`runtime/*.h`/`.c` in full, old_rice's working
`Compile/{C,IUtil,PrimOps,ToC,ToH,ToICurry}.curry` in full, and the external
`icurry` package's actual `ICurry.Types`) specifically to scope what's left
to reach a working end-to-end compiler, not just re-list known bugs. Two
findings change the shape of the plan:

1. **old_rice has a complete, working ICurry→C compiler** (`Compile/*.curry`,
   not checked into this repo but present in `~/curry/old_rice`) — per the
   dissertation's own results, it beat kics2. Rice's current
   `Rice.Codegen.C.*` is not a near-complete draft of this; it reads like an
   abandoned early sketch (undefined functions, arity mismatches, syntax
   errors throughout both `ToC.curry` and `ToH.curry`). The plan below is
   **port old_rice's working codegen**, not debug Rice's current one.
2. **The external `icurry` package's `ICurry.Types`
   (`.cpm/packages/icurry-3.3.0`) matches old_rice's own hand-rolled ICurry
   representation almost exactly** — same `IProg`/`IFunction`/`IBlock`/
   `IStatement`/`IExpr` shapes, field-for-field, down to demanded-argument
   positions and constructor numbering. This was the real risk in "port
   old_rice's codegen onto Rice" (old_rice generated its own ICurry; Rice
   gets its ICurry from a third-party package) and it isn't one — the port
   is much lower-risk than it looked. Also confirmed: Rice's existing
   `ICurry.Transforms` already *is* a port of most of old_rice's
   `Compile.IUtil` (same function names, `iname`/`isExternal`/`isVarAsgn`/
   `varsInStmt`/etc., already working), and `Rice.Codegen.Names` already has
   the name-mangling logic (`mangle`/`nameMangle`/`mangleChar`) old_rice's
   `Compile.IUtil` also provides — less new code needed than it looks.

Given the user's explicit priority — a working compiler before diving back
into the backtracking optimizations — the plan below is split into what's
needed to compile and run **basic, deterministic-or-simple-nondeterministic
programs end to end** (Phase 0/1) versus what's real, substantial, but
deliberately deferred work (Phase 2), rather than one flat bug list.

**Design review, 2026-09-03** (`src/codegen-runtime-review.md`): before
starting Phase 0, reviewed both areas for simplification and maintainability,
not just correctness. Two decisions from that review reshape the plan below:
1. **Boxed `Int`/`Char`/`Float` get one representation, not two** — resolved
   the runtime-hardcoded (`int_symbol`/`INT_CTR`) vs. codegen-generated
   dual-representation question found during the review by deleting the
   runtime-hardcoded one entirely. The `children[1]` sentinel it relied on
   answered a per-*constructor* question using per-*node* storage; it moves
   to a new `payload` field on `Symbol` itself, set once per constructor at
   codegen time as a natural part of the same struct-literal generation
   every other constructor already gets. Full design, plus a sketched
   generalization toward per-child-slot unboxed-field/GC tracking, in
   `archetecture.md`'s "Boxed primitives, and the `Symbol.payload` design"
   section. This folds into Phase 0 (runtime side: the `Symbol` field +
   updating every `children[1]`-sentinel call site) and Phase 1 (codegen
   side: emitting `.payload` for the three box constructors).
2. **`Rice.Codegen.C.C` (the C-emission DSL) gets built on `Text.Pretty`'s
   `Doc`, not `String`**, from the start of Phase 1 — not ported verbatim
   from old_rice's string-concatenating version and refactored later.
   Matches the pattern already used successfully in `PrettyFixed`/
   `ICurry.Pretty`, and avoids porting forward the exact class of bug found
   in old_rice's own copy (a missing semicolon, mismatched argument counts —
   nothing catches these until `gcc` does with a `String`-typed AST).

See `src/codegen-runtime-review.md` for the rest of the review (`PrimOps`
make/set duplication, `FunPos`-as-record, debug-build tagged-union checks,
routing every fatal path through `error()`, and the case for hand-written
runtime unit tests decoupled from codegen) — folded into the phase tables
below where it changes what gets built, and otherwise left as-is there
rather than duplicated here.

### Phase 0 — 🟢 done (2026-09-03): `runtime/`'s buildable core compiles, links, and runs

`node.h`/`macros.h`/`memory.h`/`debug.h`/`stack.{h,c}`/`runtime.{h,c}` now
build cleanly under `-Wall -Wextra -Werror` (`runtime/Makefile`, new) into
`libriceruntime.a`, and a hand-written smoke test
(`test/runtime_smoke.c`, new — no codegen, no generated `.c`/`.h` involved)
links against it and passes three checks exercising real reduction, not just
compilation: `Symbol.payload`-driven printing of a hand-built boxed value,
`choose`/`undo`/`nf_all` finding both solutions of `Choice(True, False)`,
and `fail_nf` correctly collapsing `Pair(FAIL, True)` to `FAIL`. Both
`make` (build the library) and `make test` (build + run the smoke test) work
from `runtime/`.

**`external.c` and `Prelude_external.{h,c}` are explicitly *not* part of
this buildable core** — confirmed directly while doing this phase, not just
carried over from the prior scoping pass: both `#include`/reference
per-program *generated* symbols (`Prelude__LB_RB_TAG`, `set_Prelude_True`,
`Prelude_prim_USshowCharLiteral_symbol`, ...) that don't exist until Phase 1
emits a real `Prelude.h`. They can't be compiled standalone regardless of
how many of their individual bugs get fixed — the `Symbol.payload` and
`Prelude_external.h:17` fixes below were applied to their source anyway
(cheap, isolated, reduces Phase 2's cleanup burden) but are **unverified by
compilation** until Phase 1 lands a generated header for them to build
against.

The mechanical fixes originally scoped, all done:

| Fix | File | Detail |
|---|---|---|
| `child_at_15`..`child_at_49` off-by-one | `macros.h` | Shifted one array slot from the correct pattern established by `child_at_3`..`child_at_14`. |
| `union field { ... } field;` declared a stray global variable, not a usable type | `node.h` | Added `typedef` (`typedef union field { ... } field;`), so `field lhs;` in `stack.h` and every other bare-`field` use is a real type reference. |
| `alloc(size)` not safe as a general expression | `memory.h` | **Corrected from the original plan's `do{...}while(0)`**: `alloc` is used as a *value* everywhere (`(Node*)alloc(sizeof(Node))`), so a `do{}while(0)` void-statement wrapper would have broken every call site. Rewritten as a single parenthesized comma-expression instead: `#define alloc(size) (mem++, calloc(1,size))` — bumps `mem`, then yields `calloc`'s result, safe to substitute into any expression context. `memory_init()`'s own trailing `;` (the same class of statement-context bug) dropped too. |
| `macros.h` never included | `runtime.h` | Added `#include "macros.h"`. |
| `fail_nf` referenced undeclared `node` | `runtime.h` | Fixed to `root`. |
| `fail_nf` only existed for `TEST == NO_OPTS` | `runtime.h` | Moved out of the `#if`/`#else` push_node block entirely — it doesn't depend on which `push_node` variant is active, so it's now defined once, unconditionally. |
| `make_restore` referenced never-declared `backup_symbol` | `runtime.h` | Added a placeholder `Symbol` (correctness deferred to Phase 2's case-shortcutting work — nothing calls `make_restore` yet). |
| `free()` on `GC_MALLOC`'d memory under `#ifdef GC` | `stack.c` (`stack_push`'s grow path) | Added the missing `#ifdef GC` branch (drop the old array under GC — the collector reclaims it — `free()` only under the non-GC build). |
| Syntax error, missing argument | `Prelude_external.h` | Fixed (`set_Prelude_prim_USshowCharLiteral(root, c)`) — unverified by compilation; see above. |
| `Symbol.payload` + delete the hardcoded boxed-primitive representation | `node.h`, `runtime.h`, `runtime.c`, `external.c` | The 2026-09-03 review's resolved design (see above): added `Payload` enum + `.payload` field to `Symbol`; deleted `_int_TAG`/`_char_TAG`/`_float_TAG`, `int_symbol`/`char_symbol`/`float_symbol`, `INT_CTR`/`CHAR_CTR`/`FLOAT_CTR`, `make_int`/`set_int`/`make_char`/`set_char`/`make_float`/`set_float` from `runtime.h` outright; updated every former `children[1]`-sentinel call site (`print_expr`/`print_final`/`nf`/`ground_nf` in `runtime.c`, `unify`/`lazy_unify` in `external.c`) to read `symbol->payload` instead. Verified directly by the smoke test's first check, not just by inspection. |
| No build system | `runtime/Makefile` (new) | Builds `libriceruntime.a` from the buildable core above; `-Wall -Wextra -Werror` from the start. `make test` builds and runs `test/runtime_smoke.c` against it. GC build (`-DGC`, link `-lgc`) documented in the Makefile but not verified in this environment (no `libgc` installed here) — the non-GC (`calloc`-based) build is the one actually exercised. |
| Hand-written runtime smoke test | `test/runtime_smoke.c` (new) | Bypasses codegen entirely — hand-built `Symbol`s and node graphs against `runtime.h`'s own `set0`/`set1`/`set2`/`make_choice`/etc. All three checks pass; see above. |

**Additional bugs found and fixed while actually getting this to build**
(not on the original list — found by compiling with real warnings turned
on, exactly the case the review's "get `-Wall -Wextra -Werror` running"
recommendation was arguing for):
- `set_free_constructor` (`runtime.c`) had four `:` where `;` was meant,
  a missing `;` after a `set_child_at(...)` call, and assigned a
  `union field*` directly to `children[3]` (a `union field`) instead of
  through its own `.a` member — none of these could have compiled as
  written.
- `set_child_at(r,i,v)` (`runtime.h`) expanded to `child_at_v(r,i) = v`, but
  `child_at_v` is a ternary of two `union field` *values* — in C (unlike
  C++) a `?:` result is never an lvalue, so assigning through it doesn't
  compile. Rewritten as a pointer-typed ternary, dereferenced once:
  `(*((i)<3 ? &r.n->children[i] : &r.n->children[3].a[(i)-3]) = (v))`.
- `bt_stack`/`mem` (both `extern` in `runtime.h`) were declared well after
  `push_node` and other functions that already use them — an implicit
  function/variable-use error under real warnings. Moved both declarations
  up before their first use.
- `print_stack` (`runtime.c`, debug-only) ignored its own `Stack* s`
  parameter throughout, always operating on the global `bt_stack` instead
  (unobservable in practice, since its one caller — `debug_stack`'s macro —
  always passes `bt_stack` itself), *and* its loop started at `i = size`
  rather than `size - 1`, reading one element past the end of `array`.
  Both fixed.
- `ground_nf`'s `TAG(expr) == CHOICE_TAG || TAG(expr) == FUNCTION_TAG && expr.n->missing <= 0`
  parenthesized explicitly (behavior unchanged — `&&` already binds tighter
  — but relying on that silently is exactly what `-Wlogical-op-parentheses`
  flags).
- `pop_to` (`stack.c`, unused so far — stubbed for the future depth-bounded
  backtracking optimization) compared `size_t` against `int` directly;
  guarded with an explicit `n < 0` check plus a cast.
- Several `-Wunused-parameter` fixes (`CTR_hnf`, `forward_hnf`, `undo`'s
  `cutoff` outside the `EARLY_BACKTRACKING` build) — parameters that are
  genuinely unused in the current build configuration, marked `(void)x;`
  rather than silenced by weakening the warning flags.

### Phase 1 — 🟢 done (2026-09-04): a real, working compiler, verified end to end

**Rice compiles and runs real Curry programs now** — not a claim taken on
faith from reading generated C, but confirmed by actually building
executables and running them, cross-checked against kics2's own output for
a genuinely nondeterministic program. Three programs verified:

- A literal-pattern-match + `if`/`then`/`else` program with real,
  kics2-confirmed nondeterminism (overlapping equations compiled via
  `Or`): Rice's binary prints `SOLUTION: 1` then `SOLUTION: 0`, **byte-for-
  byte matching** `kics2 :l ... main`'s own two-line output for the same
  source.
- A recursive `sumList` over a literal list: `30`, correct.
- The same `sumList`, but over `map double [1,2,3,4,5]` — exercising a
  real Prelude higher-order function, partial application, and `apply`
  together: `30`, correct.

**old_rice was not the actual port source in the end.** Scoping this pass
found old_rice's `Compile.ToC`/`ToH` call `pathList`/`getPathName`/
`descend`/`updateVars`/`getPath` — functions that don't exist anywhere in
`~/curry/old_rice` (not in `Util.curry`, not in either file itself, not in
the dissertation zip) — meaning those files don't actually compile as
checked out, contradicting the "complete, working ICurry→C compiler"
claim the 2026-09-02 scoping pass took from reading them, not compiling
them. Searching for those functions surfaced a second, previously-
unmentioned project, `~/curry/fast_backtrack` (last touched July 2025) —
structurally much closer to current Rice (depends on the external `icurry`
package directly, has `Files`/`Replace`/`Unbox`/`ANF` modules matching
Rice's own by name and role, no case-shortcutting machinery at all) — and,
with the user's direction, *that* became the actual reference, used as a
design guide rather than a literal port: its own `ToC.curry`/`ToH.curry`/
`IUtil.curry`/`ExtFuncs.curry` had their own real syntax errors and
inconsistencies too (a duplicate `litType` definition with two different
types, `Data.Map`-as-type-constructor misuse, mismatched parens throughout
`ToC.curry`), so nothing here is a straight port from either source —
`Rice.Codegen.C.{C,ToC,ToH,PrimOps}` and `Rice.Codegen.Names` were written
fresh, informed by both, and validated the only way that actually proves
anything: compiling and running the result.

Still excluded, for the reasons already scoped:

- **Case shortcutting (`RET`/`hnf_RET`)** — confirmed for real this time,
  not just by argument: the real ICurry `fast_backtrack` and the external
  `icurry` package both produce has no negative-`IVarIndex` convention or
  path-splitting at all, so there's nothing here to make dead-but-safe;
  the feature simply isn't attempted.
- **Zero-arity-constructor and small-integer flyweight preallocation** —
  every constructor, 0-arity or not, goes through the same `make_X`/
  `set_X` as everything else. No `DataTable` needed.

| Piece | What shipped | Notes |
|---|---|---|
| C-emission DSL | `Rice.Codegen.C.C` (new) | `CStmt`/`CExpr` are `Text.Pretty`'s `Doc` (not `String`) — indentation/line-breaking is structural (`nest`/`$$`), matching the idiom already used by `PrettyFixed`/`ICurry.Pretty`, not hand-threaded. `dinit` (designated-initializer entries, e.g. `.tag = X`) is kept deliberately distinct from `(.=)` (a complete, semicolon-terminated assignment *statement*) — conflating the two was a real bug shape in both reference sources, which used one combinator for both and left every call site responsible for its own punctuation. |
| Name mangling | `Rice.Codegen.Names` | Content was already correct (old_rice's `mangle`/`uninstance`/etc., ported earlier); its own module header said `CodeGen.Names`, not matching its `Rice/Codegen/Names.curry` path — fixed as part of this phase (`STYLE_GUIDE.md`'s already-flagged `Rice/Codegen/` inconsistency). `mangleChar`'s fallback (`_ -> [c]`, fixed from a type-mismatching `_ -> c` while here) also needed a real escape path for characters outside its enumerated table — found empirically: kics2's own generated "no instance or default method for class operation `...'" placeholder names contain spaces and backticks, both fatal left unescaped in a C identifier. `isStrConst` checked `m == "StringConst"` (old_rice's own convention) — Rice's real `Rice.Transform.StrLit.condenseStrings` tags a condensed string with an *empty* module name instead; the old check never matched anything Rice itself generates, found when `show True`-style code linked against a nonexistent `make___True`. |
| Primitive-operation table | `Rice.Codegen.C.PrimOps` (new) | Keyed by `(module, name)`, deliberately *not* the full `IQName` (its third component is icurry's own per-module numbering, not something this table can predict). `PrimEntry`'s three shapes (`PrimArith`/`PrimCmp`/`PrimPutChar`) each derive both their expression form (`primMake`) and statement form (`primSet`) from one description, instead of ~15 independently hand-written `make`/`set` pairs. `div`/`mod`/`round` needed real, sign-correct implementations (`runtime/prim.h`, new) — validated against `test/test.c`'s own already-worked sign-combination examples, not reinvented; `quot`/`rem` are exactly C's native `/`/`%`, no helper needed. |
| ICurry → C header | `Rice.Codegen.C.ToH` (new) | Every constructor/function gets a tag `#define`, a `Symbol` (with `.payload` set for the three box types, per the resolved design above), and `make_X`/`set_X` (`_free` variants for constructors). `setRealChildren` originally stored arguments in *reverse* order, copying old_rice's own convention uncritically — that was old_rice's own ICurry generator's internal agreement with itself, not a general ICurry property; the external `icurry` package indexes `IVarAccess`/`INodeAssign` in plain forward order, and the mismatch was invisible in every arity-1 test until a real arity-2 case (`True ? False`) silently swapped its own two arguments. Fixed to forward storage — `apply` nodes still need reversed storage for their own `missing`-driven slot trick, but that's entirely `runtime.h`'s own hardcoded `set_apply*`/`make_apply*`, unrelated to what this file generates. |
| ICurry → C source | `Rice.Codegen.C.ToC` (new) | The core translation — `showExpr`/`setExpr`/`showConsCase`/`showLitCase`. `setExpr`'s function/choice/apply cases eagerly call `X_hnf(root)` after building the node (matching both references) — an `_hnf` function's own contract requires it, not just an optional scheduling optimization: `nf`'s single, non-looping `HNF(expr)` call assumes its argument is already stable, and a `return v` (`set_forward`) left pointing at a fresh, still-unevaluated call broke that silently (a `Node*` reinterpreted as a raw `long`, printing as a huge garbage-looking integer) until this was added. A second, deeper instance of the same shape was the real bug behind `sumList`'s wrong answers: a case's dispatch loop resolves `FUNCTION_TAG`/`CHOICE_TAG`/`FORWARD_TAG` on its own reassignable local (`_scrutinee`), but the ICurry block's own later `IVarAccess`/`INodeAssign` references keep reading the *original* scrutinee variable, which the loop never updated — fixed by writing the resolved value back into the original variable (`writeBack`) at the start of every matched branch, skipped only when the scrutinee is `x0`/`root` itself (reassigning that would silently discard the function's entire result, since the caller's own copy of `root` is untouched by a callee's local reassignment). Free-variable narrowing for a *literal* case's scrutinee is the one deliberately unimplemented gap — see below. |
| Driver wiring | `Rice.Main` | `run` now writes `ModuleName.h`/`.c` (`Rice.Codegen.C.{ToH,ToC}`, `pPrint`ed) into the same per-module cache directory as the optimized-TProg cache (`Rice.Build.Cache`'s new `cPaths`), unconditionally on every compile. `main` generates a `main.c` for the root module (`writeMain`) and shells out to `clang`/`gcc` (`-x`/`--gcc` selects which) linking against `runtime/`'s buildable core plus a new minimal Prelude-primitives file (below) — assumes it's run from Rice's own project root (`runtime/` resolves relatively); a real "where is my runtime" resolution mechanism is a known Phase 1 gap, not solved here. |
| Minimal Prelude primitives | `runtime/prelude_min.c` (new) | A real, if incomplete, blocker found only by actually linking: every constructor/function `Symbol` in a generated header takes its `.hnf`'s *address* unconditionally, whether or not a given program ever calls it — so linking needs every external Prelude primitive to exist, not just the ones actually used. `external.c`/`Prelude_external.c` are the intended home but don't compile yet (Phase 2, below); rather than block Phase 1's verification on that rewrite, this is a small, independently-correct, deliberately-scoped-down file: real implementations for what's simple to get right now (`toCurryString`/`toCStr`/`setCurryString`, the strict-application operators `$!`/`$!!`/`$##`, `bindIO`/`returnIO`/`getChar`, `error` routed through the existing `error()` helper, `show*Literal`), honest `error(...)` stubs for the rest (`catch`, structural equality, file I/O, `read*Literal`) — deferred to Phase 2 exactly as before, just not silently absorbed. |

**Bugs found by actually compiling and running, not by reading** (the
theme of this whole pass — every one of these looked plausible on paper):

- **`undo` (`runtime.c`) only restored the final choice frame it popped**
  (`if(frame->choice) memcpy(...)`), contradicting its own doc comment
  ("we overwrite *all* of the node in the stack with their saved values")
  and silently defeating `save_copy`'s entire purpose: a node a `save_copy`
  frame was protecting — often the top-level root itself — stayed at its
  stale, already-computed value with nothing to prompt re-evaluation, so
  `nf_all`'s next exploration re-inspected the same already-normal-form
  value instead of the (should-have-been-restored) choice point. This is
  core backtracking machinery that Phase 0's own smoke test never
  exercised (its one test used a single 0-arity choice with no
  intervening `save_copy` frames) — the first program with real recursion
  *and* real backtracking together found it. Fixed to restore
  unconditionally, matching the comment's own stated intent.
- The `showConsCase`/`ToH` argument-order and write-back bugs above.
- `Rice.Codegen.Names`'s `isStrConst`/`mangleChar` bugs above.
- `PrimPutChar`'s expression form (`primMake`) was assumed unreachable
  (only used from `setExpr`'s statement position) and left as an `error`
  call — wrong: Prelude's own code uses it in expression position too;
  given a real `(field, comma-operator)` expression form instead.
- A tried-and-reverted design: making `HNF` itself loop through
  `FORWARD_TAG` chains and *return* where it landed, so callers without
  their own loop (`nf`/`ground_nf`) would see the fully-resolved value.
  This is real and correct for a caller like `nf` that has no loop of its
  own — but it broke `nf_all`'s backtracking loop, which depends on
  repeatedly re-examining the *same* top-level node object `undo()`
  restores by address; chasing straight through to a downstream value
  loses that identity. Reverted; documented in `HNF`'s own comment
  (`runtime.h`) so the next person doesn't try the same fix the same way.

### Verification pass (2026-09-04): old_rice's own benchmark/test suite

Before committing Phase 1, ran all 35 programs from `~/curry/old_rice/
benchmarks/` and its `test.zip` through the finished compiler — not to
benchmark performance (explicitly out of scope for now), just to confirm
real, pre-existing Curry programs actually compile and run correctly. This
surfaced one more significant bug, on top of everything in Phase 1's own
list above:

- **`apply_hnf`'s argument-fill target index was still assuming the *old*,
  reversed child-storage convention for the function being applied,
  computing `missing - 1`.** That's `f`'s own node — the same one
  `Rice.Codegen.C.ToH` generates via `make_X`/`set_X`, now forward-laid-out
  (Phase 1, above) — so the correct target is `arity - missing`, not
  `missing - 1`; the two only coincide for a completely unapplied,
  single-argument function (`arity = missing = 1`), which is exactly the
  shape of "pass a bare known function as a `map`/`filter` argument" — the
  only higher-order pattern this project's own testing had exercised before
  now. The bug: given any partial application with **2 or more** arguments
  still missing (`add3 1 2`, arity 3, missing 1), the fill wrote into an
  *already-supplied* slot instead of the real empty one, silently
  corrupting an argument and leaving the true slot `NULL` — the next read
  of it reinterpreted a null/garbage pointer as data. This single bug
  explained everything from a trivial, typeclass-free 3-argument curry
  test to `[a..b]` range syntax hanging outright (`Enum`/`Ord`'s dictionary-
  passing default methods for `Int` reach exactly this pattern). Fixed in
  both of `apply_hnf`'s branches (under/exactly-applied and overapplied) —
  see `archetecture.md`'s "Higher-order functions and partial application"
  section for the corrected account, and its own note on why this was
  invisible until now.
- Two missing `Prelude` externals found by linking real programs:
  `(&)` (committed conjunction — implemented sequentially, same
  correctness as `(&&)`'s own real, non-external definition, just without
  the concurrency a true concurrent evaluator would give a non-terminating
  operand) and `failed` (unconditional `fail`). Both added to `runtime/
  prelude_min.c`.
- **The build now passes `-O2`**, not just `-std=c11`. At `-O0`, `Rice.
  Codegen.C.ToC`'s eager `X_hnf(root)` calls (Phase 1, above) are genuine
  tail calls for a tail-recursive Curry function, but nothing guarantees a
  C compiler elides them into loops without being asked to optimize — a
  tail-recursive Curry function could still overflow the C stack on a
  large input purely for want of a compiler flag. Confirmed directly:
  `tak 33 17 8` (a classic, deliberately deep benchmark) went from timing
  out to completing correctly.

**Results after those fixes**: 9 programs run correctly outright (`fib`,
`fib_det`, `fibPeano`, `half`, `tak`, `boolComp`, `caseVar`, `lift3`,
`pick3`); several more that previously hung or crashed even at small,
non-benchmark scale (`cent`, `ndtest`, `reverse_builtin`, `sieve`,
`sumGen`) now also run correctly — confirmed both at the benchmark's own
size and with hand-written, order-of-magnitude-smaller variants built
during diagnosis (`length [1..20]`, `filter isPrime [1..100]`, a
minimal 3-argument curry test), ruling out "still just lucky at small
scale." 9 programs fail at the frontend before Rice ever sees them (old
PAKCS-only syntax, `import Integer`/`List`, or a type signature kics2 now
infers more precisely than declared) — pre-existing issues in 2023-era
source, not Rice bugs. The remainder still time out or crash on
deliberately large inputs (200k–4M element computations, or exponential
nondeterministic search over ~14 elements, e.g. `sort`'s generate-and-test
permutation) — consistent with the known, documented limitation that
Phase 1 has no trampoline and no backtracking optimizations yet (both
explicitly future work, `backtracking-optimizations.md`), not re-diagnosed
bug by bug here. One of these (`sort`, generate-and-test permutation) was
spot-checked at a much smaller scale (6 elements) and still hits the same
wall quickly with a very large trace, consistent with that explanation
rather than a distinct bug, though not exhaustively confirmed the way the
fixed issues above were.

### Phase 2 — deferred, but scoped now so it isn't lost

- **`runtime/external.c` needs a rewrite, not a patch.** Read directly this
  pass, not just re-cited from the prior list. Confirmed bugs beyond what was
  previously documented: `lazy_unify` is declared to return `bool` but bit-packs
  two values into its return (`nondet << 1 | succeed`, matching `unify`'s own,
  correctly-`int`-typed pattern) — as written, that packed value silently
  truncates to a plain `bool` on return, losing the `nondet` bit entirely.
  One of `lazy_unify`'s four `#if TEST == EARLY_BACKTRACKING` guards is typo'd
  `EARLY_BACKTRACK` (no "ING") — since that's not a defined macro, `#if`
  treats it as `0`, so that one branch's early-backtracking path silently
  activates under `NO_OPTS` instead, inconsistent with the other three correctly-spelled
  occurrences. `set_curry_String`/`Prelude_prim_USreadFile_hnf` call a
  function named `toCurryString`, but the function actually defined in this
  file is `make_curry_String` — a name that doesn't exist, not just a typo of
  one that does. `make_curry_String` itself has a missing semicolon
  (`{end++}` — not valid C, needs `{end++;}`). `Prelude_prim_USreadFloatLiteral`
  calls `set_Prelude_Int` where it should call `set_Prelude_Float` — a
  copy-paste bug of the same shape as the `cosFloat`/`sinFloat` one already
  fixed in `replace_Prim.curry`. Plus everything previously listed:
  `unify()`'s self-recursion with the wrong arity referencing undeclared
  `s`/`t`, `FUN_TAG`→`FUNCTION_TAG`, `set_free_constuctor` typo, stray
  semicolons after `if(...)` silently defeating guards (at least 3 separate
  occurrences), the `make_cstr` duplication with `Prelude_external.c`. Not
  needed for a first working program (`=:=`/`=:<=` specifically) — defer the
  rewrite, but don't patch around it piecemeal given how many of these bugs
  interact. Two more from the 2026-09-03 review to fold into that rewrite:
  route `Prelude_ensureNotFree_hnf`'s and `Prelude_prim_USerror_hnf`'s raw
  `printf`/`fprintf`+`exit()` through the existing `error(msg, expr)` helper
  `STYLE_GUIDE.md` already mandates for every fatal path; and add
  `DEBUG`-only tagged-union discipline checks for `union field` accesses
  (a shadow-tag or `assert`-based check at the `child_at_i`/`_c`/`_f`/`_n`
  access points, zero cost in release builds via the same pattern `debug.h`
  already uses) — this file's `unify`/`lazy_unify` are exactly where a wrong
  `field` variant read would do the most damage silently.
- **Case shortcutting** — no dead-but-present codegen exists to build on
  this time (Phase 1 confirmed the real ICurry has nothing to hang a RET
  marker on and didn't attempt it) — needs the marking analysis, an
  encoding that survives the external `icurry` package's plain
  `IVarIndex = Int`, and then the RET-specific codegen itself, from
  scratch.
- **Constant/flyweight preallocation** — needs a `DataTable`-equivalent
  (whole-program constructor/type info — the same gap flagged when the
  multi-module driver was originally scoped) before it's buildable at all.
- **`external.c`/`Prelude_external.c`** still need their rewrite exactly as
  scoped above — **and now need reconciling with `runtime/prelude_min.c`**
  (Phase 1, new): several `_hnf`s (`$!`/`$!!`/`$##`, `bindIO`, `returnIO`,
  `getChar`, `error`, `show*Literal`, the string-conversion helpers) now
  have real, working implementations there, verified by the programs
  Phase 1 actually ran — the Phase 2 rewrite should absorb/supersede
  `prelude_min.c` (whichever remaining stubs it doesn't cover: `catch`,
  structural equality, file I/O, `read*Literal`, plus the real
  `(=:=)`/`(=:<=)` this file was originally scoped around), not duplicate
  it or leave two competing definitions of the same functions.
- **Literal-case free-variable narrowing** (Phase 1, new, `Rice.Codegen.
  C.ToC`'s own header comment has the full account): `ICaseLit`'s
  scrutinee is assumed always already forced to a concrete literal by the
  time it's read. True for every case Phase 1's own tests exercise, false
  for a free variable of primitive type reaching a literal pattern match
  (e.g. `let x free in x + 1`) — that case fails cleanly (the same
  `fail(root)` an unmatched literal already produces) rather than risking
  undefined behavior, but doesn't produce the narrowed solutions real
  Curry semantics would. The blocker is representational, not just
  unwritten code: nothing in this codebase yet safely distinguishes "this
  `field` holds a raw scalar" from "this `field` holds a `Node*` to a
  genuine `FREE_TAG` node" without static context to lean on (the closest
  prior art, `runtime.c`'s `n.i < 1000001` heuristic in `print_expr`, is a
  fragile is-this-plausibly-a-heap-pointer guess, not something to build
  real dispatch on unverified) — resolving that is real design work, not
  a quick patch.
- **The five (six, with caching) backtracking optimizations** in
  `backtracking-optimizations.md` — explicitly next after this, not before.

## Summary counts

- 🟢 Working: **the whole compiler pipeline, source to running executable.**
  The multi-module driver (optimizer, typed rewrite engine, staleness
  cache), `runtime/`'s buildable core (Phase 0, `-Wall -Wextra -Werror`
  clean, `test/runtime_smoke.c` passing) — **plus, new as of 2026-09-04:
  `Rice.Codegen.C.{C,ToC,ToH,PrimOps}`, `Rice.Codegen.Names`, and
  `runtime/prelude_min.c`** (Phase 1) — verified by actually compiling and
  running three programs (a real, kics2-cross-checked nondeterministic
  one, a recursive one, and one exercising `map`/partial application/
  `apply` together — all three correct), not just by reading generated C.
  Plus everything already working as of 2026-08-29 (`Rice.Util`,
  `Rice.Files.*`, `PrettyFixed`, `ICurry.Goodies`, `ICurry.Transforms`, all
  of `replace/`'s targeted primitive set, `debug.h`).
- 🟡 Incomplete: `chr` clamp; `runtime/prelude_min.c` (real but
  deliberately narrow — `catch`/structural-equality/file-I/O/`read*Literal`
  are honest stubs, Phase 2); the known literal-case free-variable-
  narrowing gap (Phase 2, above); no case shortcutting or constant/
  flyweight preallocation (Phase 2, by design for Phase 1).
- 🔴 Broken: `Rice.Data.Logic.DList`; `runtime/external.c`/
  `Prelude_external.{c,h}` (still need the Phase 2 rewrite scoped above,
  now also needing reconciliation with `prelude_min.c`'s overlapping
  real implementations, not just their own pre-existing bug list).
- ⚪ Not started: Phase 2 in full (case shortcutting, constant
  preallocation, the `external.c` rewrite reconciled with
  `prelude_min.c`, literal-case free-variable narrowing, then the
  backtracking optimizations) — plus, unchanged, a general test
  framework, `read*Literal` overrides, `normalizeLimited`/constant
  folding, libraries beyond Prelude (by design), and a real "where is my
  runtime" resolution mechanism for `rice` (currently assumes it's being
  run from the project's own root).
