Codegen & Runtime: Simplification and Engineering-Practice Review
===================================================================

A design review of what's about to get ported (old_rice's `Compile/*.curry`)
and what's already sitting in `runtime/`, done *before* Phase 1/2 of
`STATUS.md`'s scope, specifically looking for (1) places the design can be
simplified, not just fixed, and (2) places better engineering practice would
make future modification easier — directly motivated by how much of
`~/curry/old_rice`'s own history was spent modifying exactly these two areas.
Cross-checked against `STYLE_GUIDE.md` throughout, since several findings here
are cases where old_rice's code (about to be ported) would violate a
convention Rice has already documented for itself.

One finding below (the boxed-`Int` question) started as a real open question
about what old_rice's own design actually is — now resolved; see the
"Resolved" note at the end of this section.

------------------------------------------------------------------------------

Resolved: two representations of a boxed `Int`
--------------------------------------------------

Reading `runtime.h` and old_rice's `Compile.{PrimOps,ToH}.curry` together
surfaced something that doesn't resolve on its own from the code alone.

`runtime.h` has its own, hardcoded, built-in notion of a boxed int:
`int_symbol` (`{.tag = _int_TAG, ...}` where `_int_TAG` is `#define`d to the
fixed value `5`), and `make_int`/`set_int` build nodes using it directly,
writing `INT_CTR` (`-1`) into `children[1]` as a discriminant.

Separately, old_rice's actual codegen path represents a boxed int as an
*ordinary, user-visible data constructor* — `Rice.Transform.Unbox`'s
`boxType` declares `Prelude.Int` as a real one-constructor type, which goes
through the completely normal `ToH.curry` `makeTags` machinery (every
constructor of every type in the whole program gets a tag assigned as
`position-in-its-type + 5`, dynamically, per program) — and `Compile.PrimOps`
separately maps the *primitive, tagless* `("","int")` value (the raw
long inside the box, which — per `Rice.Transform.Unbox`'s `primType` — has an
*empty* constructor list, no tag of its own by design) to codegen-generated
`make__int`/`set__int` functions.

These are two different mechanisms answering the same question ("this is a
boxed int") — a fixed, hardcoded tag/symbol built into the runtime itself,
versus a dynamically-assigned tag produced fresh by codegen for each
compiled program. It's not clear from the code alone whether:
- `runtime.h`'s `int_symbol`/`INT_CTR` convention is genuinely still load-bearing
  (e.g. used internally by the runtime for something codegen never touches —
  `nf`/`ground_nf`/`print_expr` all check `children[1]` against
  `INT_CTR`/`CHAR_CTR`/`FLOAT_CTR` directly), or
- it's a leftover from an earlier design iteration (the dissertation
  describes several) that predates "represent boxes explicitly in FlatCurry,
  with a real constructor," now superseded but never deleted, and what
  `nf`/`ground_nf`/`print_expr` actually need to check is whatever *codegen's*
  dynamically-assigned tag+discriminant turns out to be instead.

If it's the latter, porting both conventions forward as-is would carry a
genuinely confusing dual representation into the new Rice, where fixing a bug
in one might silently not apply to the other.

**Resolved.** It's the latter, and the fix goes further than picking one:
`runtime.h`'s hardcoded `int_symbol`/`INT_CTR` representation is deleted
entirely, not kept as authoritative. The `children[1]` sentinel it (and
`print_expr`/`print_final`/`nf`/`ground_nf`/`unify`) relied on turns out to
be answering a per-*constructor* question ("does this constructor's child
hold a raw payload, and which kind") using per-*node* storage — every call
site already knows the constructor's identity by the time it asks, so the
answer belongs on the constructor's `Symbol` (a new `payload` field, set once
at codegen time, generated the same way as `.tag`/`.arity`/`.name` already
are) rather than being re-stamped into every node instance. That leaves
exactly one representation — the codegen-generated one — with no runtime-side
counterpart to reconcile against. Full design (plus a sketched
generalization toward unboxed-field tracking for a future GC) is in
`archetecture.md`'s "Boxed primitives, and the `Symbol.payload` design"
section; not yet implemented, planned for Phase 0/1.

------------------------------------------------------------------------------

Codegen: simplification opportunities
------------------------------------------

### Represent C as a `Doc`, not `String`

Old_rice's `Compile.C` types everything as plain `String`
(`type CStmt = String`, `type CExpr = String`) and builds output by manual
list-of-lines concatenation with hand-rolled indentation (`tab n`,
`cblock b = ["{"] ++ map (tab 1) b ++ ["}"]`). This is exactly the style that
produced the concrete bugs found while reading it directly this pass — a
`return true` missing its semicolon, mismatched `cargs`/`cparams` argument
counts nothing catches until `gcc` sees them, `escChr`'s literally duplicated
`'\r' -> "\\r"` case (harmless here, but nothing would have caught it if it
weren't).

Rice already has a working, established alternative for exactly this
problem: `Text.Pretty` (the `wl-pprint` dependency), already used
successfully in `FlatCurry.Typed.PrettyFixed` and `ICurry.Pretty`. Building
`Rice.Codegen.C.C` on `Doc` instead of `String` — real structured
constructors for statements/expressions, rendered through a pretty-printer at
the end — gets correct indentation and line-breaking for free (no more
manually threading a `tab` depth through every helper), and makes the C
layer consistent with how the rest of the pipeline already handles
pretty-printing, rather than being the one place that does it differently.
It also opens the door to catching malformed construction (wrong arity to a
call, mismatched brace nesting) as a Curry-level type error instead of only
surfacing once `gcc` runs.

**This is a real, if modest, amount of extra design work up front** — new
`CStmt`/`CExpr` constructors and a renderer, not just porting old_rice's
string-concatenating helpers one-for-one. I'd still recommend doing it *as*
Phase 1, not string-first-then-refactor-later: porting the string version
first means deliberately building something with the exact failure mode just
found in old_rice's own copy, then redoing the work anyway to fix it — more
total effort than building it right once, using the two existing examples in
this codebase as the template.

### Derive `PrimOps`'s "set" form from its "make" form

Every entry in old_rice's `Compile.PrimOps` table hand-writes *two*
independent representations of the same operation — an expression-building
`make` function (`\[x,y] -> "(field)(long)("++x++" + "++y++")"`) and a
statement-list `set` function (`\root [x,y] -> [root++".i = "++x++" + "++y++";"]`)
— for every single primitive, roughly fifteen times over. Nothing enforces
these stay consistent with each other, and it's exactly the kind of
duplication that drifts silently (fix a bug in one, forget the other).

Since C unions support direct assignment, `set` is mechanically derivable
from `make` for every one of these: `set root es = [root .= make es]`. Worth
confirming there's no primitive where `make`/`set` genuinely need to differ
(none of the ones read this pass do — they're all "compute a value, put it in
a `field`"), but if that holds, this collapses ~15 duplicated definitions
into one generic combinator plus one `make` expression per primitive.

### `FunPos`, and similar positional tuples, should be records

`Compile.ToC`'s `FunPos = (Path, [IVarIndex], IQName)` gets threaded
positionally through most of the module's functions (`showBlock`, `showStmt`,
`save`, ...) as an unnamed 3-tuple. `STYLE_GUIDE.md` already states Rice's own
preference here directly: *"Reach for a record only when a type genuinely has
several independent, named config-style fields"* — `FunPos` is exactly that
case (old_rice's own single record example, `CompileOptions` in
`Rice.Codegen.Options`, already exists as a precedent, just needs actually
using elsewhere). A record makes every call site self-documenting
(`pos.path` vs. the second element of a 3-tuple you have to trace back to
`showConsCase`'s pattern match to identify) and makes it possible to add a
field later without touching every call site's positional pattern.

------------------------------------------------------------------------------

Codegen: engineering-practice notes
----------------------------------------

- **Stay inside the DSL, don't fall back to raw string concatenation.**
  `showConsCase`'s `nondetCode` (the RET/backup logic — already flagged in
  `STATUS.md` as the densest, most bug-prone-looking part of the file) mixes
  the `.=`/`scall`/`cif` combinators with raw `++`-concatenated string
  literals inconsistently, in the same function. A `Doc`-based rewrite (above)
  makes this enforceable structurally; even without that, treating "always go
  through the DSL, never hand-build a fragment with `++`" as a hard rule for
  this file specifically would help, since it's already the part most likely
  to need real changes once case-shortcutting (Phase 2) actually gets
  implemented against it.
- **Module naming**: `STYLE_GUIDE.md` already documents the exact
  inconsistency in the current `Rice/Codegen/` tree (`CodeGen`/`Codegen`/
  `codegen` casing, missing `Rice.` prefixes) and names `Rice.Codegen.*` as
  the target. The port is the natural point to actually fix this, not just
  note it again.
- **Doc comments**: old_rice's `Compile.*` has essentially none. Per
  `STYLE_GUIDE.md`'s stated bar ("every exported function should get at least
  a one-line `---` doc comment"), the port is the point to add them —
  cheapest to write while the translation logic is freshly re-understood,
  expensive to reconstruct later from generated-C output alone.

------------------------------------------------------------------------------

Runtime: engineering-practice notes
----------------------------------------

### Route every fatal path through the existing `error()` helper

`STYLE_GUIDE.md` already states this as the intended convention
(`runtime/runtime.h:192`'s `error(msg, expr)`) and already flags a few
existing violations. Reading `external.c` directly this pass turned up more:
`Prelude_ensureNotFree_hnf` (`printf(...); exit(0);`) and
`Prelude_prim_USerror_hnf` (raw `fprintf`+`exit`) both bypass it. Small, but
worth fixing as part of the same pass that touches this file for Phase 2 —
one consistent failure path makes it possible to, e.g., hook a single place
later if error reporting ever needs to change (line numbers, a stack trace,
whatever), instead of hunting down every ad hoc `exit()`.

### Add debug-build type-discipline checking for `field`

This is the concrete, actionable version of a real structural risk worth
naming plainly: `union field` carries *no* type information of its own —
whether a given `field` value is meaningfully a `Node*`, a `long`, an
`unsigned long`, or a `double` is determined entirely by context (the node's
tag, or the `children[1]` sentinel convention discussed above), and using it
as the wrong variant is silent undefined behavior with no compiler check
possible — C's type system fundamentally can't help here, by construction.
This isn't a case for ripping out the union (it's the entire mechanism
unboxing's performance story depends on), but it's exactly the kind of area
that benefits from *extra*, deliberate discipline precisely because the
normal safety net (the type checker) is absent.

Concrete proposal: `debug.h` already provides leveled, `#ifdef DEBUG`-gated
macros that compile to nothing in release builds — this is exactly the right
place to add a parallel, debug-only tagged-union discipline check. E.g. a
`DEBUG`-only shadow tag (or a set of `assert`-based helpers used at the
`child_at_i`/`child_at_c`/`child_at_f`/`child_at_n` access points) that
verifies the accessed variant actually matches what the current tag/context
implies, and traps immediately instead of silently reading garbage. Zero cost
in release builds (same pattern `debug.h` already uses), and it converts
exactly the class of bug that's hardest to find (wrong-answer-at-runtime, no
crash, no compiler warning) into an immediate, loud failure at the point it
happens rather than downstream where the cause is no longer visible.

### Build + lint infrastructure is the single highest-leverage change here

Worth stating plainly, because it explains *why* bugs like the ones found
this pass and last (`unify()`'s wrong-arity self-recursion, the
`toCurryString`/`make_curry_String` name mismatch, `lazy_unify`'s
`bool`-typed bit-packing truncation, `EARLY_BACKTRACK` vs
`EARLY_BACKTRACKING`) exist at all: `runtime/` has never been compiled as a
whole. Several of these are things `gcc -Wall -Wextra -Werror` catches
immediately and unconditionally (an undefined-function reference is a *link*
error, not a subtle one) — they've had no opportunity to be caught, not
because they're hard to catch. Phase 0's Makefile should turn on
`-Wall -Wextra -Werror` from the very first commit that makes `runtime/`
build at all, not as a later cleanup pass — every bug in this review and the
last one would have been caught immediately by a compiler that was actually
being run.

### Test the runtime independently of codegen

Right now the plan (`STATUS.md`'s Phase 0 → Phase 1) only lets the runtime be
exercised *after* codegen also works, since the only way to get a program
into it is through generated C. That serializes two independently-testable
concerns unnecessarily. A small number of hand-written `.c` test files —
bypassing codegen entirely, building a few small node graphs directly with
the `make_X`/`set_X` functions and calling `apply_hnf`/`choose`/`undo`/`nf`
against them — would let Phase 0's fixes be verified in isolation and would
give Phase 2's `external.c` rewrite (`unify`/`lazy_unify` specifically, given
how many interacting bugs were found there) something to actually run against
before codegen exists to generate `=:=` call sites for it. This also directly
serves the eventual backtracking-optimizations work: those need measurable,
repeatable test programs regardless, and small hand-written graphs are a
natural first tier below whole compiled Curry programs.

### The `TEST`-as-ordinal-macro pattern is the same issue, already flagged

`backtracking-optimizations.md`'s implementation plan already recommends
replacing the current `#if TEST == NO_OPTS / PUSH_NONDET / ...` ordinal
progression with independent, per-optimization compile-time flags, for
exactly the "easier to modify, testable in isolation" reasons this review is
about — noting the connection explicitly so it doesn't read as a separate,
uncoordinated recommendation: it's the same practice applied to the same
piece of code, motivated from two different conversations.

------------------------------------------------------------------------------

Summary
-----------

Two things worth doing *before* Phase 1 starts, not after: resolving the
boxed-`Int` question above (affects what actually gets ported), and deciding
whether to build `Rice.Codegen.C.C` on `Doc` from the start (affects how
Phase 1 gets built, not just what it produces). Everything else here —
`PrimOps` derivation, `FunPos`-as-record, the debug-build tagged-union
checks, routing through `error()`, the Makefile's warning flags, and
hand-written runtime tests — can be folded into Phase 0/1/2 as they happen,
without changing the phase boundaries `STATUS.md` already lays out.
