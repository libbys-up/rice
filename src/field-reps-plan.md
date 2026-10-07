Plan: field reps (which node children are raw values)
=====================================================

Written 2026-10-05. Comes before the explicit stack and the precise GC,
because both depend on it. Order of work: **this → worker/wrapper
unboxing → explicit stack → GC.**

The goal: at every point where the runtime or codegen looks at a node's
child or a function's local variable, it knows exactly whether that slot
holds a pointer or a raw `Int#`/`Char#`/`Float#`. It never guesses.

Types are still erased before ICurry, as the standard Curry pipeline does.
Field rep information travels next to the program in a **side table**, computed
at the last typed stage.

------------------------------------------------------------------------------

Why this is needed now (not just later)
---------------------------------------

Raw children already exist in today's output, before any worker/wrapper
pass:

- **Box constructors** (`Prelude.Int`/`Char`/`Float`, built by `Unbox`).
  Their single child is raw. This is the one case the runtime handles
  today, via `Symbol.payload`.
- **External function nodes whose parameters are raw.** `prim_putChar`
  takes a `Char#`. `prim_showIntLiteral` and friends take `Int#` etc.
  (`PrimOps.curry`'s header says why these are real `_hnf` functions and
  not inlined). A suspended `prim_putChar c#` node has a raw child, but its
  symbol says `PAYLOAD_NONE`. So `print_expr` (`runtime.c:665`) would call
  `print_expr` on a `long`, and any future GC would trace it as a pointer.
- **Raw locals in generated C**: case-bound box fields and `PrimOps`
  results.

All the generic child walkers currently assume "a box, or else every child
is a pointer". This plan replaces that with a per-slot answer.

------------------------------------------------------------------------------

Design
------

### Field reps

```curry
data FieldRep = RPtr | RInt | RChar | RFloat
```

Record the specific primitive, not just "raw". Printing needs to know which
one it is, and so will future unboxed returns. In C this is
`enum { R_PTR = 0, R_INT, R_CHAR, R_FLOAT }`, with `R_PTR` equal to zero
so a zeroed array means "all pointers".

`fieldRepOf :: TypeExpr -> FieldRep` is `TCons Int#` → `RInt` (and the same for
`Char#`/`Float#`, the names in `Unbox.int'`/`char'`/`float'`). Everything
else is `RPtr`. **A type variable is always `RPtr`.** Raw values never
instantiate polymorphic positions (GHC's levity rule, enforced by the lint
in step 2).

### The side table

```curry
data FieldRepTable = FieldRepTable
  { frCons :: Map QName [FieldRep]                  -- constructor fields
  , frFuns :: Map QName [FieldRep]                  -- function parameters
  , frVars :: Map QName (Map VarIndex FieldRep)     -- every variable, per function
  }
```

Where each part comes from (all in the current module's `TProg`, after
ANF, just before `removeTypes`):

- `frCons`: from the module's type declarations (constructor argument
  types). That's the boxes today, and unpacked constructor fields if those
  ever come back.
- `frFuns`: from each `TFunc`'s *declared type*, splitting off the first
  `arity` argument types (after stripping `ForallType`). Using the type
  rather than the parameter variables means **externals get covered too**,
  which is exactly the `prim_putChar` case.
- `frVars`: every binder in a typed body (parameters, `TLet`,
  `TPattern` variables, `TFree`), from the type annotation on the binder.
  It isn't needed by codegen until the explicit stack, but it's computed
  now so the lint can use it, and so it's already tested when the explicit
  stack arrives.

**Why variable indices survive:** ICurry keeps FlatCurry's variable numbers
(`toIExpr (Var v) = IVar v`, and the same in `toIBlock`). The one exception
is `caseVar`, a fresh variable invented when a case scrutinee isn't a
variable. Full ANF guarantees it always is, and the lint asserts it.

**Cross-module:** `ToH` only emits symbols for the module's *own*
functions and constructors. Calls to imported functions go through their
own module's `make_X`/`set_X`, which take plain `union field`s. So
layouts need no imported tables. The only place that needs imported
information is the lint, for checking calls *into* other modules. It can
get callee types from the driver's `FunTable`, which already holds typed
`TFuncDecl`s for everything compiled so far.

**Caching:** the table is recomputed from the post-ANF `TProg` on every
codegen run (which already happens after the cache). Nothing new is
persisted.

------------------------------------------------------------------------------

Steps
-----

### 1. Compute the table

**Done 2026-10-06.** `Rice.Codegen.FieldReps` and `--print-fieldreps`.
Building it exposed one gap upstream of it: functions taken from
`replace/replace_Prim.curry`/`replace_Prelude.curry` had their signatures
renamed into `Prelude`, but not the type annotations inside their rules.
`flatcurry-typed`'s `updQNamesInTFunc` only renames calls and pattern
constructors. So pattern variables like `eqInt`'s `x'` were still typed
`replace_Prim.Int_SH`, and the table read them as pointers.
`Rice.Files.Replace.updTypeQNamesInTFunc` now renames those annotations
too. Generated C is unaffected, since `removeTypes` drops annotations.

- New module `Rice.Codegen.FieldReps`: `FieldRep`, `FieldRepTable`, `fieldRepOf`,
  `fieldRepTable :: TProg -> FieldRepTable`.
- `Rice.Main`: compute it from `anf` right next to `removeTypes anf`
  (`Main.curry:172`), and pass it to `toHeader`/`toSource`.
  `removeTypes` itself stays unchanged.
- `--print-fieldreps` flag (in the style of `--icurry`) to dump the table.
  Cheap to add, and it's how the field rep information gets eyeballed while
  unboxing is being developed.

### 2. Field-rep lint (catch unboxing bugs at compile time, not as segfaults)

**Done 2026-10-06.** `lintFieldReps`, run by `--lint-fieldreps` (also on
with `--debug`) for every module that gets regenerated. `tests/run.sh`
passes the flag on every compile. The driver now also threads an
accumulated `FieldRepTable` (constructors + function parameters, via
`interfaceReps`) through its fold, so calls into other modules are
checked. String literals (`StrLit`'s module-less 0-ary constructors) are
exempt. It also checks that every literal is raw.

Its first run over the Prelude found three real bugs, all now fixed:

- `Unbox.nestCase` annotated the inner variable of a literal case with
  the *boxed* type while binding it as raw (`toEnum` for `()`, `Bool`,
  `Ordering`).
- Functions from `replace/replace_<M>.curry` never went through
  `condenseStrings`/`unbox`, because `replace` runs after both. Their
  literals stayed raw at boxed types, so `aValueNat`'s `n+1` built
  `case 1 of Int x -> ...` on a raw `1`, and `=:<<=`'s error string was a
  list of raw chars in pointer slots. `Replace.replace` now runs both over
  the replacement module first. `replacePrim` is untouched, since
  `replace_Prim.curry` is written at the raw level already.
- `Replace.updName` renamed string literals' empty-module names into the
  target module. It now leaves module-less names alone.

`Rice.Codegen.FieldReps.lint :: FunTable -> FieldRepTable -> TProg -> [String]`.
On by default under `--debug`, and run over the whole test suite and the
Prelude, which must come out clean. It checks:

- Every call argument's field rep matches the callee's parameter field rep: own
  functions and constructors via the table, imported ones via `FunTable`
  types, `PrimOps` entries via their declared types.
- No raw value in a polymorphic position (callee parameter is a type
  variable), in `?`/`TOr`, in `TFree`, or as an argument of a *partial*
  application (`FuncPartCall`/`ConsPartCall`). That last one is the
  "workers are never partially applied" invariant.
- Constructor cases only scrutinize `RPtr` variables, and literal cases
  only scrutinize raw ones.
- Every case scrutinee is a variable (so ICurry's `caseVar` never
  appears).

### 3. Symbols carry field reps (`ToH`, `node.h`)

**Done 2026-10-06.** `node.h`'s `Payload` enum is now `FieldRep`
(`R_PTR = 0, R_INT, R_CHAR, R_FLOAT`), and `Symbol.payload` is
`const unsigned char* reps`. `runtime.h` has `child_rep(sym, i)` and
`box_rep(sym)`. `box_rep` requires a constructor tag (`> FREE_TAG`) and
arity 1, so `prim_putChar`'s thunk isn't mistaken for a box. All twelve
`payload` checks in `runtime.c`/`prelude.c` now go through `box_rep`.
`ToH.toHeader` takes the module's `FieldRepTable` and emits
`static const unsigned char X_reps[]` only for symbols with a raw slot. In
the Prelude that's 7: the three boxes, `prim_putChar`, and the three
`prim_show*Literal`s. The inlined `PrimOps` entries have no symbols at
all. `boxPayload`'s hard-coded names and `C.symPayload` are gone.
Behavior is unchanged: the walkers still special-case boxes only, which
step 4 generalizes.

- `Symbol` gets `const unsigned char* reps`. `NULL` means "all
  pointers", so the common case costs no data. `ToH` emits
  `static const unsigned char X_reps[] = {...}` only for symbols with at
  least one raw slot.
- **Replace `payload`.** Box-ness becomes a helper:
  `is_box(sym)` = constructor tag, arity 1, `reps[0] != R_PTR`. The
  existing `PAYLOAD_INT` checks become `box_rep(sym) == R_INT`. This
  stops being exact if raw fields are ever unpacked into user
  constructors. At that point, add an explicit flag. Don't add it before
  then.
- `boxPayload`'s hard-coded `Prelude.Int`/`Char`/`Float` match in `ToH`
  goes away. Box layouts come from `frCons` like everything else.
- Built-in symbols (`runtime.h:513-524`) need no `reps` array. Rule to
  document in `node.h`: **walkers only look at slots `[0, arity)`, and a
  slot at or beyond `arity` must never hold a pointer.** `choice_symbol`
  keeps its raw `side` in slot 2 (arity 2) under that rule. `FORWARD` is
  all pointers.

### 4. Make every child walker rep-aware (`runtime.c`, `prelude.c`)

Add `child_rep(sym, i)` to `runtime.h`: `sym->reps ? sym->reps[i] :
R_PTR`. Then go through every loop over `symbol->arity`:

| Site | Change |
|---|---|
| `print_expr` (`runtime.c:609`) | print raw slots by field rep, not by recursing (fixes the latent `prim_putChar`-thunk bug) |
| `print_final` (`:819`) | box case via `box_rep`. Constructor children use `child_rep` too |
| `nf` (`:1034`), `ground_nf` (`:930`) | skip raw slots instead of stopping at boxes only |
| `unify_step` (`prelude.c:547`), `lazy_unify_step` (`:721`) | compare raw slots by value per field rep, recurse on pointer slots |
| generated `set_X_free`/`make_X_free` (`ToH.setConFree`/`makeConFree`) | emitted for every constructor, boxes included: for a constructor with a raw field, emit a body that raises the same "can't narrow a raw value" error instead of writing `free_var()` into the slot |
| `set_copy_free` (`runtime.c:152`) | narrowing makes all children free variables, so assert the layout is all-pointers. A raw slot is a clear runtime error ("can't narrow a raw value"), not a free variable written into an `Int#` |
| `apply_hnf` fill (`:302`, `:371`) | assert each filled slot is `R_PTR` (no worker partial applications) |
| `set_copy`, `save_snapshot`, `choose` | no change: whole-node `memcpy` copies the symbol along with the fields |
| `print_frame`, `debug_expr`, and any other debug printer | go through `print_expr` |

Partial nodes: with forward storage, a partial application
(`missing > 0`) has filled only its first `arity - missing` slots. The
last `missing` are NULL until `apply_hnf` fills them. `filled_arity(n)`
(`runtime.h`) gives the count, and the rule is written down in `node.h`.
`apply` nodes (`missing < 0`) have arity 0 and keep their arguments
outside this scheme, so the GC will need them as a special case.

**Done 2026-10-06.**

- `print_expr`: the `n.i < 1000001` guess is gone. A raw child prints
  by its rep through `print_raw` (Curry literal syntax), a pointer
  child recursively, and NULL as `NULL`. So `prim_putChar('k')` shows
  correctly under `--debug`.
- `print_final`: boxes go through `box_rep` + `print_raw`; other
  constructors check each child's rep.
- **Both printers walked children last-to-first and tested
  `i >= missing`**, the old reversed-storage convention. `print_final`
  showed `T 1 True 'x'` as `T('x', True, 1)`. Both now go first-to-last
  and use `filled_arity`. No golden printed a multi-argument user
  constructor, which is why this went unnoticed.
- `nf`/`ground_nf`: walk only filled pointer children. The box early
  return is subsumed by that.
- `unify_step`/`lazy_unify_step`: compare raw children with
  `raw_equal`, recurse into pointer children.
- `set_free_constructor(n, like)` (lazy unification's narrowing) now
  takes the node being matched. Raw children copy its values, pointer
  children get free variables, so `x =:<= 3` binds `x` to `Int(3)`. It
  also allocates its spill array with `alloc`, not `malloc`, so Boehm can
  see the pointers in it.
- `set_copy_free` (currently unused) and the generated
  `set_X_free`/`make_X_free` for a constructor with a raw field call
  `narrow_raw_error`. A free `Int` reaching a box case (`f x = x + 1`
  with `x` free) now stops with "can't narrow a free variable to Int"
  instead of writing a free-variable pointer into the raw slot.
- `apply_hnf`: `check_fill_ptrs` (debug builds only) checks that every
  slot it fills is a pointer slot.

### 5. Debug-mode layout check

**Done 2026-10-06.** `check_layout(n, allow_null, where)` in `runtime.c`
checks that every filled `R_PTR` child looks like a node pointer:
past the first page, pointer-aligned, with a plausible symbol pointer.
It's gated by a new `CHECK_LAYOUT` macro, which is on by default at
`DEBUG >= MED` and on alone with `-DCHECK_LAYOUT=1`, so the whole suite can
run with it (`RICE_CFLAGS=-DCHECK_LAYOUT=1 tests/run.sh`) without debug
trace output breaking the goldens. Generated `set_X`/`make_X` call it with
NULL allowed. `nf`/`ground_nf` call it with NULL not allowed.

Two things it needed:

- **Locals are zero-initialized** (`C.fieldDecl`: `field x = {0};`). A
  recursive `let` passes a variable to `make_X` before `INodeAssign`
  fills it in. It used to be an uninitialized read, which is undefined
  behavior, and it would have tripped the check with stack garbage.
- **ICurry invents functions after the table is built.** Its case
  lifting (`FlatCurry.CaseLifting`, inside `ICurry.Compiler`) turns
  nested cases/lets/frees into `<top-level fn>_<CASE|COMPLEXCASE|LET|FREE><n>`,
  whose parameters are the top-level function's variables under their
  original indices. The table had no entry for them, so they defaulted to
  all pointers. The check's first run caught `f_CASE8` holding a raw 5.
  `FieldReps.addLiftedReps` now fills them in after ICurry generation,
  from the origin's `frVars`, matching parameter positions through the
  body's `IVarAssign i (IVarAccess 0 [p])`. In the Prelude that took
  symbols with a `reps` array from 7 to 170. The lint still only sees the
  typed program, so lifted functions aren't linted directly. Their bodies
  are pieces of linted functions, though, and the layout check covers
  their nodes at runtime.

Checked in both directions: the scratch programs pass with the check on,
and a header with `f_CASE8`'s `.reps` deleted by hand fails at
`set_FrTest__f_USCASE8` with "child 1 of f_CASE8 should be a node pointer
(R_PTR) but holds 0x5".

`check_layout(node)` under `DEBUG >= MED`: for each `R_PTR` slot in
`[0, filled_arity(node))`, assert it's non-null and pointer-aligned, and that its
`symbol` field is non-null. Call it from generated `set_X`/`make_X`
(`ToH`) and on entry to `nf`. This catches a *wrong table* (for example a
pointer slot holding a raw value) at the point of construction, which is
exactly the bug class unboxing will produce.

### 6. Tests

**Done 2026-10-06.** Six tests in `tests/programs/regressions/`:

| Test | Guards |
|---|---|
| `fieldrep_ctor_order` | `print_final`'s child order (`T(1, True, 'x')`, not reversed) |
| `fieldrep_lazy_unify` | `=:<=` copying raw values into a narrowed box (`x =:<= 3`) |
| `fieldrep_strict_unify` | `=:=` comparing boxes' raw children (equal unify, different fail) |
| `fieldrep_narrow_raw` | a free `Int` reaching a box case stops with the narrowing error (`rice-exit: 1`) |
| `fieldrep_lifted_case` | ICurry-lifted functions with raw parameters, built under `CHECK_LAYOUT` |
| `fieldrep_debug_print` | a `--debug=high` build (`CHECK_LAYOUT` + lint on) runs clean, exit status only |

The goldens for `ctor_order`, `lazy_unify`, `strict_unify` and
`lifted_case` match KiCS2's values (Rice's `T(...)` print syntax aside).
KiCS2 can't `=:<=` a free `Float` ("No generator for C_Float"), so the
lazy-unify test sticks to `Int`/`Char`.

`run.sh` gained three per-test directives (documented in
`tests/README.md`): `rice-flags:`, `rice-exit:`, and `rice-golden: none`.

Not covered: the debug printer on a *function* node with a raw `Float`
child (the case the old `n.i < 1000001` guess would have dereferenced).
Every such node tried so far is evaluated before the trace prints it.
Also not covered: Int narrowing through `aValueNat` (step 2's `replace`
fix). It enumerates forever by design, so no finite goal reaches it.

- Regressions that put raw children in suspended nodes today, so they
  pass through the changed walkers: a lazily-unused
  `putChar (chr (ord c + 1))` inside a data structure printed under
  `--debug=high`, `show` of a computed `Int` inside a lazy pair, and
  `=:=`/`=:<=` on boxed values nested in constructors.
- Run the lint over everything in `tests/programs/` and the Prelude, and
  make "lint clean" part of `tests/run.sh` (a compile flag, so nothing
  extra gets run).
- The existing suite must be unchanged (56 goldens).

### 7. Then: bring back worker/wrapper

Port old_rice's `Optimize/Strictness.curry` (`fixStrict`/`splitWorker`)
onto `TExpr`. Two differences from old_rice:

- **Give workers real types.** old_rice gave workers `TVar 0` (types
  erased). Here the worker's `TFunc` type has to list `Int#` for unpacked
  box fields, because `frFuns` is derived from function types. With real
  types, the field rep table, the symbol layouts and the lint all cover workers
  with no further work.
- Enforce the invariants from the earlier discussion, all of which the
  lint now checks: only call workers in a strict position, never partially
  apply one, and the wrapper evaluates (and so pulls up choices and
  handles free variables) before it calls the worker.

### Later: explicit stack and GC

- Explicit stack: when `ToC` splits a case into continuations, each
  frame's layout is the `frVars` field reps of the variables live at that
  point. Emit one field-rep array per continuation, in the same format as
  symbols.
- GC: traces slots `[0, filled_arity)` where `child_rep == R_PTR` (plus
  `apply` nodes' arguments, which sit outside that range), plus
  frame slots by their continuation's field reps. No conservative scanning is
  needed for heap or frames.

------------------------------------------------------------------------------

Open questions
--------------

- `print_expr`/`print_final` format floats with `%lf`, which doesn't match
  Curry's `show` for `Float`. Fixing that while touching these functions is
  cheap. Should it be in scope?
- Should the lint also run (silently) on every normal build? It's
  probably cheap next to ICurry generation. Measure before deciding.
