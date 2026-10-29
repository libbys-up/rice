# Runtime history

This file holds the history that used to live in comments in `runtime/`:
bugs we fixed, approaches we tried and dropped, and why some code ended up
the way it is. The code comments now describe only the code as it stands
(see `STYLE_GUIDE.md`, "Three kinds of comments"). The big picture design is in
`src/developers-manual.tex`, and the compiler's history is in
`src/compiler-history.md`.

Entries are grouped by the file and function they're about. If you change one
of these places, check here first, because a lot of these are traps someone
has already fallen into.

## runtime.h

### `HNF` does a single `.hnf` call, on purpose

We tried a version of `HNF` that kept going through FORWARD nodes and returned
where it ended up. We reverted it, because it broke `nf_all`. `nf_all` keeps
re-examining the same top-level node, which `undo()` restores in place by
address. When `HNF` chased straight through to a value further down the chain,
the caller lost track of that node, and the second search looked at a value
that was already reduced instead of the choice point `undo()` had just put
back.

### The optimization flags are separate 0/1 switches

The backtracking optimizations used to be one ordinal level. They're mostly
independent, so comparing them properly means trying combinations, not a
line. That's why each one has its own `-DOPT_...` flag. The defaults are the
set we've validated; #4 and #5 are off because they aren't validated yet.

### `current_epoch` and `TrailEntry.epoch` exist even with #5 off

They're declared unconditionally so `trail.c` doesn't need any `#if`. With
#5 off nothing increments `current_epoch`, so saving and restoring it in each
trail entry is a harmless round trip.

### Scoped retry (#3)

`SCOPED_RETRY` started out as the hand-written retry in `lazy_unify_step`
(prelude.c) and was generalized to every generated `_hnf`. It doesn't add new
recursion: if the choice it flips was buried inside the scrutinee's own call,
re-reading the scrutinee lands on FUNCTION again, and the case loop's existing
`case FUNCTION_TAG: HNF(scrutinee)` handles it the same way it always did.

### Copy collapsing keeps root's nondet flag

`set_copy` would overwrite root's nondet flag with the target's (always
false, by `collapse_safe`). But root's flag records root's own history. For
example, `showConsBranch` may have just `save_copy`'d root, which sets the
flag right before the collapse. So `collapse` saves and restores it.

### Removed: `apply1_hnf`, `apply2_hnf`, `apply3_hnf`

These just tail-called `apply_hnf`, and nothing used them. The code generator
calls `apply_hnf` directly. They were described as "a chance for optimization
in the future".

## node.h

### `Node.missing` is 16 bits (2026-10-28)

`missing` used to be an `int`. With `OPT_EPOCH_TRAIL` on, the 4-byte `epoch`
didn't fit in the first word after it, so `symbol` moved to offset 16 and every
node grew from 48 to 56 bytes. That extra word was most of #5's fixed cost on
deterministic programs (`current.md`, 2026-10-27). With all flags on, best of
7–9 runs, int vs `int16_t`, against #5 off:

| program | 56 bytes | 48 bytes | #5 off |
|---|---|---|---|
| ReverseBuiltin | 0.146 s | 0.110 s | 0.107 s |
| PrimesBuiltin | 3.308 s | 3.156 s | 3.177 s |
| `scaled/pakcs/mergesort_or` | 0.519 s | 0.481 s | 0.480 s |
| TakPeano | 1.094 s | 1.085 s | 1.076 s |

## runtime.c

### `apply_hnf` fills the first empty slot, counting up

The fill index is `arity - missing`, counting up. It used to be `missing - 1`,
which matched old_rice's reversed child storage. That stopped being right when
`Rice.Codegen.C.ToH` switched to forward storage. A completely unapplied
one-argument function makes the two formulas agree (both 0), which is exactly
what passing a bare function to `map` or `filter` looks like, so the first
higher-order tests passed. It only showed up once something had two or more
arguments missing (`add3 1 2`, or a curried dictionary method, which is how
`[a..b]` reaches it): the argument overwrote one that was already supplied, and
the real empty slot stayed NULL. We found it by running old_rice's benchmark
suite through the finished Phase 1 compiler. The over-applied branch had the
same bug and the same fix.

### `undo()`'s cutoff check

The loop always pops at least once. Before the `size <= cutoff` check, a
scoped caller with an empty scope (a function whose parent pushed an entry
before tail-calling it) would pop and restore an entry that belonged to its
parent. For cutoff 0 the check is the same as the old `size == 0` test.

### `push_frame` is used

It used to be commented "Not sure this is used." It is: the generated code for
a FREE scrutinee (`freeCaseBlock` in `ToC.curry`) pushes
`(scrutinee -> fresh free variable)` with it.

### Removed: `set_copy_free`

Nothing called it, and it was broken: it allocated a fresh node but never set
the node's symbol, and it ignored its `new_node` argument. Narrowing uses
`set_free_constructor` and the generated `set_X_free` functions instead.

### Printing bugs

- `print_tuple` used to print its closing paren in its `i == 0` case, and
  printed the current index before recursing, so every tuple printed from its
  last component to its first.
- `print_string`, `print_list` and `print_final` read `(:)`'s children
  backwards (tail as head). Nothing had printed a list or string as the
  top-level result until `tests/run.sh` got its crash detection (STATUS.md),
  so it went unnoticed. `putStr` goes through `toCStr`, which was already
  right.
- `print_final` checked for a constructor named `"char"`, which never matched
  anything. The boxed Char constructor is `"Char"`.
- `print_string` used to write raw bytes between quotes, so a string with a
  newline or a backslash printed unescaped. It now uses `appendEscaped`, the
  same escaping as `show`.
- `print_final` used to match tuples with 15 hard-coded string compares.
  `tuple_commas` replaced them, so tuples of any size print as tuples.

### `appendEscaped`

We checked the context-dependent quote escaping (a bare `"` is fine inside
`'x'`, and a bare `'` is fine inside `"..."`) against real KiCS2's `show`.

## prelude.c

### Why so many primitives use `settle()`

Several primitives used to evaluate an argument once and then read its tag.
That breaks whenever the argument ends up as a FORWARD node, which is common
(`choose()` always leaves one, and a dictionary method often forwards to
another call). The fix each time was `settle()`.

- `(&)`: it called `nf(x)` and then read `x`'s tag. `nf` takes its argument
  by value, so it never updates the caller's `x`. When `x` was a FORWARD, the
  tag check matched neither FAIL nor False and fell through to "must be True",
  throwing away a real False. `(1 /= 1) & e` forwarded to `e`. We traced it
  with `--debug=high` to `/=`'s dictionary dispatch ending on a FORWARD.
- `strictApply`, `cond`: same problem, same fix, before `(&)`.
- `toCStr`: every caller used to pass a fully evaluated string, so it read
  tags directly. `read*Literal`'s callers pass strings built lazily by
  `lexDigits`/`span`, and walking the unevaluated spine segfaulted.
- `prim_ioError`: `ioError` forces its argument with `$##` before we get here,
  so the settle is defensive.

### `settleStringNode` reads the box's child

The head of a cons cell is a boxed Char node, so the character is
`child_at_c(head, 0)`. When `settle()` was first added here, it regressed to
reading `head.c`, the `Node*` reinterpreted as a char. A `read` round-trip
test caught it with garbage output.

### `bindIO` commits its choices

Settling `m` can dispatch a choice (`m` is `x ? y`, or something inside it is).
`choose()` pushes a trail entry, and then `apply_hnf` overwrites root with f's
result, so nothing can reach that choice anymore. The entry stayed on the
trail, and `nf_all`'s `undo(0)` later found it, restored it, and re-ran `nf()`
on a graph that hadn't changed. That showed up as a second "SOLUTION: ()" for a
plain `do` block containing a `?`. The regression test is
`tests/programs/regressions/bindio_orphaned_choice.curry`. This cutoff is also
the property a future `catch` needs from the trail.

It also has to fully settle `m`: a single evaluation, or a loop that only chased
forwards, wasn't enough. Without it, `f` (usually `\_ -> next`) got a FORWARD to
the rest of the `do` block and threw it away, so pending actions never ran.

### `ensureNotFree`

Real KiCS2 (`external_d_C_ensureNotFree` in `Prelude.kics2.hs`) chases
through Choice/Guard nodes and narrows an unbound free variable. We can't
narrow, because we don't know the type. `$#`/`ensureNotFree` don't appear in
`replace_Prelude.curry` or `replace_Prim.curry`, or in the `__KICS2__` branch of
`Prelude.curry` that Rice compiles (only in the CPP branches for other
backends), so we only get here if a Curry program calls them itself.

### History of the file

`prelude.c` replaced the old `external.c`/`external.h` and
`Prelude_external.c`, which implemented overlapping externals differently and
had raw `exit()` calls (see STATUS.md, Phase 2).

### Unifying a variable with itself

`x =:= x` and `x =:<= x`, with `x` free, used to hang. `unify_step` and `lu_k`
bound the variable to the other side without checking whether the other side
was the same variable, which made a FORWARD pointing at itself, and any later
read of `x` looped forever. Found 2026-10-24 during the readability review.
`main = let x free in x =:= x &> x =:= True &> x` hung, while KiCS2 and PAKCS
both print `True`. Both functions now check for the same node first. The
regression tests are `tests/programs/regressions/self_unify.curry` and
`self_lazy_unify.curry`.

This is not an occurs check, and we still don't do one. For `x =:= C x`
(with `data T = C T | N`), PAKCS does an occurs check and fails, while KiCS2
doesn't and succeeds with a cyclic term. Like KiCS2, Rice has no occurs check.

## Open questions found during the readability review

- (Resolved 2026-10-27.) `src/archetecture.md` said a case must not update the
  original variable past a forward chain, but `writeBack` in `ToC.curry` does
  exactly that. Both are right: `writeBack` changes the C local, never the
  graph. The developer's manual ("Generated code") says so now.
