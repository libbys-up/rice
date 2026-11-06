# Compiler history

This file holds the history that used to live in comments in the compiler
(`src/Rice/`, `replace/`): bugs we fixed, approaches we tried and dropped,
measurements, and why some code ended up the way it is. The code comments now
describe only the code as it stands (see `docs/style-guide.md`, "Three kinds of
comments"). The design is in `docs/developers-manual.tex`, and the runtime's
history is in `docs/history/runtime-history.md`.

Entries are grouped by module. If you change one of these places, check here
first, because a lot of these are traps someone has already fallen into.

## Rice.Main

### `-O2` and tail calls

Before the evaluation machine, generated code made eager `X_hnf(root)` calls
for tail calls, and nothing guaranteed the C compiler would turn them into
jumps. At `-O0` it didn't, so a tail-recursive Curry function could still
overflow the C stack. That's why `-O2` was added. Now every tail call is a
`musttail` jump at every optimization level, and `-O2` is only there for
speed.

### The object cache's header check

`compileObj` recompiles an object when a header is newer than it. At first
every module's generated `.h` counted too, so touching one module's source
recompiled every object in the program, Prelude's and the runtime's
included. A module's `.h` and `.c` are always written together, so the
`.c`-vs-`.o` check already covers the generated headers; only the
hand-written runtime headers count now.

### The `.o.flags` file is written with plain `writeFile`

It used to be written with `writeFileIfChanged`, which reads the file again.
Together with `readIfExists`, that was two reads of the same file in one
`compileObj` call, and in practice one raced with the write and failed with
"resource busy (file is locked)". Now there's one read, forced right away.

### Why there's a `.rfcy` cache

After the optimizer, the rest of the pipeline costs as much as optimizing:
for Prelude, ANF alone took about 7s and writing the `.h`/`.c` another 10s
(`--compiler-time`). A module that isn't stale produces exactly the same
output, so we read the `.rfcy` and keep the old `.h`/`.c`.

## Rice.Build.Deps and Rice.Build.Cache

### The `.rimports` cache

KiCS2's derived `Read` instance for `TProg` isn't incremental. Forcing any
one field parses the whole `.tfcy`: forcing just `tProgImports` on Prelude
(which is `[]`) took the same ~4s as reading everything, for a ~2MB file.
Building the module graph only needs names and imports, so we cache those
separately.

### `writeFileIfChanged` forces the old contents

`readFile` is lazy, and the handle stays open until the string is forced. We
force it with ``length s `seq` `` before deciding whether to write. (An old
comment wondered whether `normalForm` would do; `length` is enough for a
`String`.)

## Rice.Diagnostics

KiCS2's `getCPUTime` reports milliseconds. Earlier ad hoc timing code
labeled the numbers "ps".

## Rice.Optimize.Inline

### `caseCancel` looks through `TTyped`

An annotated literal like `(3 :: Int)` is `TTyped (TLit ...) Int`, and
`caseCancel` used to match only a bare `TLit` or `TComb`. So
`if (3 :: Int) == 4 then 1 else 0` left `eqInt`'s inlined box case
uncancelled, and the C compiler failed with "use of undeclared identifier".
The same program without the annotation worked.

### `stripTyped` and `isIOType` use `case`

Both were first written as two equations, a specific pattern and a
catch-all. In Curry those overlap, so each was nondeterministic. For
`isIOType`, that made `deadCode` choose between dropping and keeping *every*
dead `let`, and the whole optimized module carried an unresolved choice.
Forcing it in `writeOptIfChanged`'s `show` failed with "Non-determinism in
IO occured", which reached us as KiCS2's "List data with no ground term".
`stripTyped` reintroduced exactly the same symptom the first time it was
written. See `docs/style-guide.md`, "Pattern matching".

### `deadCode` keeps `IO` bindings

`deadCode` used to drop any unused `let`. A `do` block's non-final statement
can become `let _ = statement in rest`, so this dropped effects. In
`tryPrint.curry` it was one of two reasons a trailing newline printed before
the string it followed (the other is `prim_putChar`, below).

### `subGrounded` checks its arity

`subGrounded` used to `zip` parameters with arguments, which silently drops
the extras. When `replace_Prelude.curry` gave `(=:=)` a `Data a =>`
constraint, the replacement got a third (dictionary) parameter that no call
supplied; inlining dropped it and left a reference to an unbound variable,
which surfaced much later as "undeclared identifier" from the C compiler.

### The planned `normalizeLimited`

The plan was a limited ANF pass before the optimizer, naming calls and case
scrutinees but not constructors and literals, to give `inline`'s
`let`-cancelling rules more to do. It was never written, so the optimizer
runs on the output of `replace`, and `reduce`, `caseCancel` and `deadCode`
do most of the work.

## Rice.Optimize.FunTable and Rice.Transform.Order

Both were ported from old_rice (`Optimize/FunTable.curry`,
`Optimize/LoopBreakers.curry`) onto typed FlatCurry. `makeFunTable`'s
comment pointed at a `recursiveNames` that doesn't exist; the loop breakers
come from `orderFuns`.

## Rice.Util and fresh variables

### `vars` missed case-pattern variables (fixed 2026-10-28)

`unbox` used to start its fresh-variable counter at `maximum (vars e)`, and
`vars` left out variables bound by case patterns. A literal case nested under
a constructor case then got a box variable with the same number as a pattern
variable:

```
g (Just k@1) = k + 10
```

`k` was `v2`, and the new `Int v2` pattern shadowed it. The field rep lint
caught it ("variable 2 is bound as RInt but used at type RPtr");
`tests/programs/regressions/unbox_fresh_var.curry` is the test. `vars` is gone.
`unbox` and `normalize` now start from `updProgFresh`, which also counts the
function's parameters, since a parameter the body never uses still has a
number.

### The optimizer's counter ignored parameters too (fixed 2026-10-28)

The rewrite engine (`FlatCurry.Transform.Typed.ExecDet`) started its
fresh-variable counter from the body alone, so a `let` made by inlining could
reuse the number of a parameter the body never uses. I couldn't make this
fail: ICurry only declares parameters the body uses, so the two never meet in
the C. `transformRuleDet` now counts the parameters, and `optimizeProg` and
`--trace-optimize` use it.

### Difference lists

`Rice.Data.Functional.DList` and `Rice.Data.Logic.DList` were an experiment in
building the generated C more efficiently than with `String`. It didn't pan
out, and the modules were deleted on 2026-10-28, along with the unused
`Rice.Codegen.CodeGen` and `Rice.Codegen.Options` (an older, string-based code
generator). The logic version showed that the standard logic programming
difference list isn't efficient in Curry: it relies on binding a free variable
being a pointer update, and in KiCS2 a free variable is a generator. That's
worth looking at again (developer's manual, "Planned work").

## Rice.Codegen.Names

- Ported from old_rice's `Compile.IUtil`. Its module header used to say
  `CodeGen.Names`.
- `mangleChar` had no catch-all. KiCS2's placeholder names for missing
  instance methods ("no instance or default method for class operation
  `...'") contain spaces and backquotes, which ended up in C identifiers.
- `isStrConst` used to check old_rice's `m == "StringConst"`, which nothing
  Rice generates matches. A program using `show` built `make___True`
  instead of a string constant.

## Rice.Codegen.C.C

- The DSL replaced old_rice's `String`-based one, where every helper
  threaded its own indentation. It's built on `Text.Pretty`'s `Doc` instead.
  old_rice's case-shortcutting helpers (`ret_hnf`, `backup`, `nbackup`,
  `make_restore`, `fwd`, `isRET`, `hasRET`) weren't ported, since nothing
  would call them yet.
- old_rice's `(.=)` returned an expression without the `;`, and every call
  site had to add it, which they often didn't. It's a complete statement
  now, and designated-initializer entries have their own `dinit`.
- `cinclude` used to include the whole dotted module name. That worked for
  every module without a dot and failed for the first hierarchical one
  (`clang: fatal error: 'Test.Prop.Types.h' file not found`).
- `varName` used to call variable 1 `scrutinee`, as both reference
  implementations did, assuming ICurry reserves it for case scrutinees. It
  doesn't. When the scrutinized variable happened to be number 1, the case
  loop's copy came out as `field scrutinee = scrutinee;`, which reads the
  uninitialized new local. The loop's copy is `_scrutinee` now.
- `cblock` put the line break before the `nest`, so the first statement of
  every block in the generated C wasn't indented (fixed 2026-10-27).

## Rice.Codegen.C.ToH

- `setRealChildren` used to store arguments in reverse, copying old_rice.
  That was an agreement between old_rice's own ICurry generator and its
  code generator; the `icurry` package Rice uses indexes children forward.
  Every arity-1 test passed. The first arity-2 function (`True ? False`)
  swapped its arguments.
- old_rice's `writeMain` preallocated every 0-ary constructor and every `Int`
  in [-127, 128] as shared nodes, which needs a whole-program table of data
  types. Rice doesn't do this.

## Rice.Codegen.C.ToC

- `writeBack` exists because a branch reads the scrutinee's children
  through the scrutinee variable. Without it, the variable still pointed at
  an intermediate FORWARD node, and a recursive function read a `Node*` as a
  raw `long`: right control flow, wrong arithmetic. It skips `root`, since
  reassigning the local `root` would leave the caller's node unrewritten.
- ICurry can declare a variable twice in one block (Prelude's `_def#===#...`
  methods do), hence `dedupDecls`.
- `uncaseTrail`: with #1 off, every rewrite has to be trailed, including
  one outside any constructor case. Without it #5 alone was unsound
  (`tests/programs/regressions/stale_apply.curry`, whose `o` is a
  let-lifted function with no case; see `opt_conflict.md`).
- A literal case can't narrow a free variable. An older plan was to tell a
  raw value from a free variable at run time, and the only prior art was
  `print_expr`'s `n.i < 1000001` guess at whether a word is a pointer.
  Field reps made this unnecessary: narrowing to a box is an error.
- `Interactive` mode (`nf_all`) was the compiler's original behavior.

## Rice.Codegen.C.PrimOps

- The table was checked against the names Rice really generates
  (`--icurry` on a test program), not old_rice's `primAddInt`-style names.
- `prim_putChar` used to be inline, which ran it as soon as control reached
  its `let`, before earlier output. That was the other cause of the early
  newline in `tryPrint.curry`.
- The table is keyed without ICurry's index; matching on it made every
  lookup miss.
- `primMake`/`primSet` derive both forms from one entry, instead of old_rice's
  15 hand-written `make`/`set` pairs (`docs/history/codegen-runtime-review.md`).

## replace/

- `replace_Prelude.curry`'s `(=:=)` and `(=:<=)` used PAKCS's types, with a
  `Data a =>` constraint. See `subGrounded` above.
- `replace_Prim.curry` said `chr` clamps its argument to 0..1114111.
  `prim_chr` never did.
