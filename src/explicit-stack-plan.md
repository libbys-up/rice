Plan: an explicit evaluation stack
==================================

Written 2026-10-07. Replaces "raise the stack limit" (`--stack-size`,
`set_stack_size`) and the `OPT_TAIL_JUMP` trampoline with a design in the
style of GHC's STG machine, while still compiling to C:

- Rice keeps its own evaluation stack in the heap.
- Every transfer of control is a guaranteed tail call
  (`__attribute__((musttail))`).
- The C stack stays at constant depth no matter how deep the Curry
  evaluation goes.

The same structure is what a precise, moving GC needs: every live pointer
is either in a stack frame (whose layout is known) or in a node (whose
layout `Symbol.reps` gives). See "GC readiness" below.

Toolchain check (2026-10-07, Apple clang 21, arm64): `musttail` together
with `__attribute__((preserve_none))` compiles and runs a 100M-deep
mutual tail recursion in constant stack, at both `-O2` and `-O0`.

------------------------------------------------------------------------------

Where Rice uses the C stack today
---------------------------------

Generated code (`Rice.Codegen.C.ToC`):

- **Case scrutinee evaluation.** `ICaseCons`'s dispatch loop does
  `case FUNCTION_TAG: HNF(scrutinee); break;`. That is a non-tail call,
  and the main source of depth: every pending case is a C frame.
- **Tail calls.** `setExpr` builds the callee's node over `root`, then
  calls `g_hnf(root)` directly through `TAIL_DISPATCH`. That is constant
  space only if clang turns it into a sibling call. With `OPT_TAIL_JUMP`
  on, the trampoline makes it constant-space instead.

Runtime (`runtime.c`, `prelude.c`):

| Routine | Nested evaluation | Depth grows with |
|---|---|---|
| `apply_hnf` | `HNF(f)`, re-entrant `apply_hnf(root)` when over-applied | over-application chains |
| `nf`, `ground_nf` | `HNF_SETTLE`, then recurse into children | depth of the data (a long list) |
| `nf_all`, `run_io` | `nf` | (driver; bottom of the stack) |
| `bindIO` | `settle(m)` then `apply_hnf` | nesting of `>>=` on the left |
| `&`, `cond`, `ensureNotFree`, `prim_ioError`, `$!`/`$!!`/`$##` | `settle(x)` / `nf` / `ground_nf` | argument depth |
| `constrEq` (`=:=`) | `nf` both sides, then `unify_step` recursion | data depth |
| `nonstrictEq` (`=:<=`) | `lazy_unify_step` recursion with `HNF` | data depth |
| printers | recursion over the value | data depth |

Every one of these becomes either a machine routine (it pushes a frame
and tail-jumps) or a leaf (it never evaluates anything).

------------------------------------------------------------------------------

The machine
-----------

### Code, frames, and the stack

```c
typedef struct Frame Frame;
#define RICE_CC __attribute__((preserve_none))
typedef RICE_CC void (*Code)(void);

typedef struct FrameInfo {
    Code code;                  // what to run when this frame is returned to
    unsigned short size;        // number of slots
    const unsigned char* reps;  // FieldRep per slot (NULL: all pointers)
    const char* name;           // for --debug and error messages
} FrameInfo;

struct Frame {
    const FrameInfo* info;
    union field slots[];        // `size` of them
};
```

- **The stack** is one contiguous, growable array of slots (`Stack`,
  separate from the backtracking trail `bt_stack`). Frames are pushed and
  popped at the top. Nothing ever points into it except the stack
  pointer, so growing it by `realloc` is safe.
- **The stack pointer** lives in a global, `rice_sp`, to start with. The
  GC needs to find it at any allocation, and a global is the simplest way
  to guarantee that. Passing `sp` as an argument to keep it in a register
  is a later optimization, measured with `tests/bench.sh`.
- **Uniform signature.** Every piece of machine code, generated or
  runtime, has the same signature, `RICE_CC void k(void)`. Its inputs come
  from `rice_sp`'s top frame and from `rice_root` (below). Identical
  signatures are what `musttail` requires.
- **`rice_root`** is the machine's one "register": the node the current
  code is rewriting. Generated code still refers to it as `root`.
  Whenever execution may leave the current code block, it also lives in a
  frame slot, so the GC sees it.

### Returning

When a function has put `root` in head normal form (it built a
constructor, failed, or bound a forward), it returns by jumping to the
code of the frame on top of the stack:

```c
#define RETURN() __attribute__((musttail)) return rice_sp->info->code()
```

The bottom of the stack holds a sentinel frame whose code ordinarily
returns to C. The C driver (`eval_hnf(node)`, used by `nf_all`, `run_io`,
and any not-yet-converted runtime routine) pushes the sentinel, sets
`rice_root = node`, calls `node->symbol->hnf()`, and gets control back
when the sentinel runs. Each nested driver call costs one C frame, so
converting a routine to the machine removes its depth. Unconverted
routines keep working through the driver in the meantime.

### Calling

A tail call is a jump. `setExpr` overwrites `root` with the callee's node
exactly as now, then:

```c
__attribute__((musttail)) return g_hnf();
```

The callee returns to whatever frame the caller would have. This makes
`TAIL_DISPATCH`, `TAIL_DISPATCH_PTR`, `HNF_SETTLE`, and `OPT_TAIL_JUMP`
unnecessary.

------------------------------------------------------------------------------

Code generation
---------------

### One code block per constructor case

Evaluation only ever happens at one place: a constructor case whose
scrutinee isn't in head normal form yet. So **each `ICaseCons` becomes its
own C function**, the "case block". The case's own frame is its
continuation:

- The function body up to its first case is the **entry block**
  (`f_hnf`): declarations, assignments, then either a return (no case) or
  a jump into the case block.
- Entering a case block pushes the case's **frame**. That frame holds
  every variable the case and its branches use (`root`, the scrutinee,
  and the free variables of the branches), plus the dispatch loop's own
  state as raw slots: `nondet` and the `SCOPED_CUTOFF` value.
- The dispatch loop runs as it does now, except for the `FUNCTION_TAG` /
  `CHOICE_TAG`-needs-evaluation step. Instead of `HNF(scrutinee)` it sets
  `rice_root = scrutinee` and jumps to the scrutinee's code. The case's
  own frame is already on top, so when the scrutinee returns, the case
  block is simply re-entered. It re-reads its variables from its frame
  and re-runs the dispatch, which handles the `FORWARD_TAG`/`FAIL_TAG`/...
  result exactly as the current loop does after `HNF` returns.
- A branch ends in a tail position (ICurry's statement is always last).
  So before a branch's final return, tail call, or nested case, the case
  pops its own frame. A nested case then pushes its own frame. The stack
  therefore holds exactly one frame per *pending scrutinee evaluation*,
  which is the same thing the C stack holds today, and a self-recursive
  tail call holds none.
- A literal case (`ICaseLit`) never evaluates anything (its scrutinee is
  already a raw value), so it stays inline in whichever block contains it.

Sketch for `len xs = case xs of [] -> 0; (_:t) -> 1 + len t` (after
inlining, roughly `case xs of [] -> Int 0; (:) _ t -> case len t of Int n
-> Int (n+1)`). The `len t` case pushes a frame, so this is the non-tail
recursion that overflows today:

```c
static const unsigned char len_CASE1_reps[] = {R_PTR, R_PTR, R_INT, R_INT};
static const FrameInfo len_CASE1_info = {len_CASE1, 4, len_CASE1_reps, "len/case1"};

RICE_CC void len_hnf(void) {            // entry block: root = len(xs)
    HEAP_CHECK(0); STACK_CHECK(4);
    PUSH(&len_CASE0_info, root, child_at(root,0), /*nondet*/0, /*cutoff*/CUTOFF());
    __attribute__((musttail)) return len_CASE0();
}

RICE_CC void len_CASE0(void) {          // case xs of ...
    // slots: 0 root, 1 xs, 2 nondet, 3 cutoff
    for(;;) switch(TAG(SLOT(1))) {
      case FUNCTION_TAG: rice_root = SLOT(1);
                         __attribute__((musttail)) return SLOT(1).n->symbol->hnf();
      case FORWARD_TAG:  SLOT(1) = child_at(SLOT(1),0); continue;
      case CHOICE_TAG:   choose(SLOT(1)); continue;
      ...
      case Prelude__Nil_TAG:  { field r = SLOT(0); POP(); set_Int(r, 0); RETURN(); }
      case Prelude__Cons_TAG: {             // tail position: replace our frame
          field r = SLOT(0), t = child_at(SLOT(1),1);
          POP(); HEAP_CHECK(sizeof(Node)); STACK_CHECK(4);
          field call = make_len(t, 0);
          PUSH(&len_CASE1_info, r, call, 0, CUTOFF());
          __attribute__((musttail)) return len_CASE1();
      }
    }
}
```

`len_CASE1` (the case on `len t`) evaluates `call` the same way, then
builds `Int (n+1)` over `SLOT(0)`, pops, and `RETURN()`s. The C stack
never grows; the explicit stack grows by one 4-slot frame per element,
like any non-tail recursion has to.

### What goes in a frame

For a case at some position in a function's ICurry body:

- `root`, if the case or anything after it writes `root` (always, in
  practice);
- the scrutinee variable;
- the free variables of all its branches. These are known from the ICurry
  block structure. `src/ICurry/Goodies.curry` has `allVars*` (every
  variable in a body) but no free-variable function yet, so one needs
  writing (variables used in the subtree minus those it declares);
- `nondet` (raw), `cutoff` (raw).

The slot reps come from `FieldRepTable.frVars` (variables) plus `R_INT`
for the two raw loop-state slots. `addLiftedReps` already covers
ICurry-lifted functions. Each case gets one static `FrameInfo`, with a
`reps` array only when it has raw slots, the same convention as `Symbol`.

Raw *return values* (unboxed results from future worker/wrapper workers,
`field-reps-plan.md` step 7) don't occur yet: the field-rep lint forbids a
raw result. If they're added, the returned value goes in a second machine
register (`rice_ret`), and the continuation's `FrameInfo` records its rep.

------------------------------------------------------------------------------

Runtime routines
----------------

### Evaluate-and-resume

Most hand-written primitives follow `x = settle(x); ...use x...`. That
becomes a frame whose code is the rest of the primitive, plus a shared
helper:

```c
// Push a frame for `k` with `n` slots, then evaluate `x`; `k` runs when
// x is settled (past FORWARD_TAG), with x in its frame's slot 0.
#define EVAL_THEN(k_info, x, ...)  ...
```

This covers `bindIO`, `&`, `cond`, `ensureNotFree`, `prim_ioError`,
`$!`, and `returnIO` (a leaf).

### Converted individually

- **`apply_hnf`.** The `while(f.n->missing <= 0)` loop's `HNF(f)` becomes
  evaluate-and-resume back into `apply`. The over-applied case's recursive
  `apply_hnf(root)` becomes a jump.
- **`nf`/`ground_nf`.** These become machine routines with a frame
  `(node, next child index)`. Visiting a child pushes a frame for the
  parent's next index and jumps to `nf` on the child. Depth moves from
  the C stack to the explicit stack, which can grow without limit. A long
  list's spine is the common deep case, and it also gets a cheaper
  special case: iterate down the last pointer child instead of pushing.
- **`nf_all`/`run_io`.** These stay C drivers at the bottom of the
  machine. Their backtracking loop (`undo`, then re-run `nf` on the same
  root) runs between machine runs, when the explicit stack is empty.
- **`constrEq`/`nonstrictEq`.** The unification recursions become machine
  routines with an explicit work list of `(x, y)` pairs. `constrEq`'s
  `nf` of both sides reuses the `nf` routine.
- **Printers.** Plain C recursion over already-normal data. They don't
  evaluate anything, so their depth is separate from the machine's. Make
  `print_list`/`print_string` iterate down the spine, which removes the
  realistic deep case.

### Leaves (unchanged except for the signature)

`CTR_hnf`, `forward_hnf`, `choice_hnf`, `failed`, the `show*Literal`s,
`putChar`, `getChar`, `readFile`, `writeFile`, `appendFile`, `error`.

------------------------------------------------------------------------------

Backtracking
------------

Nothing about choice points moves. The trail stays in `bt_stack`, and
`choose`/`undo`/`push_choice` keep their meaning:

- **`SCOPED_RETRY`** (`OPT_SCOPED_BACKTRACK`) retries within one case's
  dispatch loop. That loop is now one case block, and the cutoff it
  compares against is in the case's frame. It still only rewinds the
  trail and re-dispatches. It never unwinds the explicit stack.
- **Failure** is an ordinary return: `fail(root)` then `RETURN()`. The
  caller's case block sees `FAIL_TAG` on re-entry, as it does now after
  `HNF` returns.
- **`nf_all`'s outer retry loop** runs only when the machine is idle (the
  explicit stack is at its sentinel). That matches today, when it runs
  with no Rice C frames above it.

The explicit stack doesn't need to be part of a choice point's snapshot.
Rice backtracks by undoing graph rewrites from the trail and
re-evaluating from the root, not by capturing continuations. This is
worth re-checking against `OPT_SCOPED_BACKTRACK`'s code when that code is
converted.

------------------------------------------------------------------------------

GC readiness
------------

This design is what makes a precise, moving GC possible:

- **Roots** are `rice_root`, every frame's `R_PTR` slots (via
  `FrameInfo.reps`), the trail (`bt_stack`: whole-node snapshots, each
  with its own symbol), and runtime globals.
- **Safe points.** Code allocates only after a **heap check** at the
  start of a block: the entry block, and each case-branch entry. The
  check reserves the block's maximum allocation (known statically: the
  number and arity of `make_X` calls on the longest path to the next
  jump). It runs before any allocation, when everything live is in
  `rice_root` or a frame, so a GC there sees all roots. After it, the
  block bump-allocates with no further checks, so C locals holding fresh
  nodes are never live across a GC. This is GHC's heap-check discipline.
- **Runtime allocation** of unbounded size (`choose`'s snapshot,
  narrowing's `set_X_free`/`push_choice`, `apply_hnf`'s copy, string
  primitives) does its own heap check first. It may only run at a point
  where every live pointer is in a frame. Case blocks satisfy this,
  because their variables live in frame slots, not C locals.
- **Stack check.** Each block also checks it has room for the largest
  frame it pushes (`STACK_CHECK(n)`) and grows the stack if not.

Until the GC exists, `HEAP_CHECK` is a no-op and allocation stays
`calloc`/Boehm. The checks can land with the codegen change, as no-ops,
so the GC work later only changes what they expand to.

------------------------------------------------------------------------------

Staging (each stage keeps `tests/run.sh` green)
------------------------------------------------

Status:

- **Stage 1 done 2026-10-07.** `runtime/machine.{h,c}` (added to the
  `Makefile` and `Rice.Main`'s link list). The stack grows *downward*,
  as GHC's does, so popping a frame needs only its own `info->size` and no
  back-link word. `machine_grow` copies the used region to the top of a
  block twice the size. `HNF` goes through `eval_hnf`, which checks the
  stack is balanced when it returns. The runtime smoke test pushes
  100,000 frames (two growths) and checks every slot.
- **Stage 2 done 2026-10-07.** `RICE_CC` and `Code` live in `node.h`, and
  `Symbol.hnf` is a `Code`. Every `_hnf`, generated or hand-written, is
  `RICE_CC void f_hnf(void)` and starts with `field root = rice_root;`.
  Calls set `rice_root` first (`hnfCall`, `TAIL_DISPATCH*`, `eval_hnf`).
  `C.cparams []` prints `(void)`.
- **Stage 3 done 2026-10-07.** `ToC` lifts each `ICaseCons` into a case
  block `f_hnf_case<k>` with a static `FrameInfo` (slots: root, scrutinee
  as it began, current scrutinee, the branches' free variables, then raw
  `nondet` and cutoff; reps from `frVars`). Entering a case pushes its
  frame and jumps in. `FUNCTION_TAG` saves the loop state and jumps to the
  scrutinee's code. Branch exits pop the frame first (`leave`; a frame is
  present exactly when the retry context is `Just`). `setExpr` returns its
  exit: `RETURN()` or a `musttail` jump for calls, `?` and `apply`. The
  hand-written runtime `_hnf`s became C-convention `X_impl` bodies behind
  machine-convention `X_hnf` wrappers (`impl(); RETURN();`). Their nested
  evaluations, and `TAIL_DISPATCH*`, go through `eval_hnf` until stage 4.
  `SCOPED_SAVE_CUTOFF`/`SCOPED_LOAD_CUTOFF` carry the cutoff through
  frames. `regressions/deep_nontail_recursion` (`len` over a million
  elements) passes on the default 8 MB C stack. `foldr (+) 0 [1..10^6]`
  still overflows: its `(+)` goes through `apply_hnf`, which is still
  C-nested.
  `tests/run.sh --slow`: `reverse_prim` (262,144-deep non-tail reverse)
  now runs, so it moved from XSLOW to SLOW with a golden. **`perf/tailsum`
  regressed** (segfault). Its `sumTail $! (acc + n)` passes through
  `$!` and `apply_hnf` on every iteration. Their calls back into machine
  code are nested `eval_hnf`s now, where clang used to turn them into
  sibling calls, so ten million iterations exhaust the C stack. Stage 4
  makes both machine routines. (`cent`'s golden was re-recorded: it
  predated the field-rep printing fix and listed constructor arguments
  reversed. All 528 solutions are the same, in the same order.)
- **Stage 4, first half, 2026-10-07.** On the machine: `apply` (frame
  `[root, f, nondet]`; the over-applied case now stores the copied call as
  the function child and re-enters `apply`, whose own loop evaluates it),
  `$!`, `&`, `cond`, `ensureNotFree` (evaluate-and-resume via
  `settle_step`/`EVAL_OR_CONTINUE`, frame `[root, x, nondet]`), `bindIO`
  (settle frame, then a one-slot commit frame that runs `pop_to` once
  `apply f m` is in head normal form), and `Prelude.apply` (a jump).
  `$!!`/`$##` still force their argument with nested `nf`/`ground_nf`,
  but their final apply is a jump. Now passing:
  `regressions/deep_apply_foldr` (`foldr (+) 0 [1..10^6]`),
  `regressions/deep_io_chain` (200,000-step right- and left-nested
  chains), and `perf/tailsum` again. Still nested: `nf`/`ground_nf`, the
  two unify routines, `prim_ioError`'s settle (it exits anyway), and
  `toCStr`'s string settling.
- **Stage 4, second half, 2026-10-07.** `nf`/`ground_nf` are one
  machine routine (`nfx_k`, frame `[expr, settled, state, mode]`, one
  frame per pending child, last child first as before). The C functions
  `nf`/`ground_nf` are drivers for it through the new `machine_run(code,
  x)` (`eval_hnf(x)` is `machine_run(x's hnf, x)`). `=:=`'s `unify_step`
  needs no evaluation (both sides are already normal), so it uses an
  explicit heap work list in the same depth-first, left-to-right order.
  `=:<=` runs on the machine: one frame per pending pair
  `[s, t, scruts, scrutt, phase, child, nondet, cutoff]`, the result
  passed back through `lu_result`, and the scoped-backtracking retry
  restarting the pair in place. New tests: `regressions/deep_nf`
  (`$!!` on a million elements), `regressions/deep_unify` (`=:=` and
  `=:<=` on million-element lists).

  Noticed, not changed: `=:<=`'s settle loops evaluate only
  `FUNCTION_TAG` and treat a `CHOICE_TAG` node as a value, where every
  other settle loop resolves choices. That may be a latent bug, worth a
  test of its own.
- **Stage 5 (cleanup) done 2026-10-08.** Removed `OPT_TAIL_JUMP`,
  `TAIL_DISPATCH`/`TAIL_DISPATCH_PTR` and `HNF_SETTLE` (C code that needs a
  settled value calls `eval_hnf`), `--stack-size` with
  `set_stack_size`/`raise_stack_limit`, and `StackSize` from `ToC`/`Main`.
  `tests/bench.sh` has no tail-jump configuration any more.

1. **Machine core** (`runtime/machine.h`/`.c`): `Frame`, `FrameInfo`,
   the growable stack, `PUSH`/`POP`/`RETURN`, the sentinel and the C
   driver `eval_hnf`. `HNF(x)` becomes `eval_hnf(x)` everywhere it's
   called from C, which is still nested, still working.
2. **Signature change.** Every `_hnf` becomes `RICE_CC void f_hnf(void)`,
   reading `root` from `rice_root`. This touches `ToH`'s declarations and
   `Symbol.hnf`'s type, plus every hand-written `_hnf`. Behavior is
   unchanged; the suite must stay green.
3. **Generated code on the machine.** Case blocks, frames with
   `FrameInfo`/reps, `musttail` tail calls, `RETURN()`. Add a test that
   overflows today: a non-tail recursion 1,000,000 deep (`len` or
   `foldr (+) 0 [1..1000000]`).
4. **Runtime on the machine.** Evaluate-and-resume for the `settle` users,
   then `apply_hnf`, then `nf`/`ground_nf`, then the unify routines. Add
   tests that `nf` of a 1,000,000-element list and `=:=` on two such lists
   both work.
5. **Remove** `OPT_TAIL_JUMP`, `TAIL_DISPATCH*`, `HNF_SETTLE`,
   `--stack-size`/`set_stack_size`. Run `tests/bench.sh` against the
   commit before stage 1.
6. **Then the GC:** `HEAP_CHECK`/`STACK_CHECK` become real, and a
   copying collector traces roots via `FrameInfo.reps` and nodes via
   `Symbol.reps`. Separate plan.

`--debug` support comes with stage 1: print the frame stack (names and
slots, via `print_expr`/`print_raw` by rep). `CHECK_LAYOUT` extends to
frames: check every `R_PTR` slot when it's pushed.

------------------------------------------------------------------------------

Open questions
--------------

- **Portability.** `musttail` needs clang 13+ or GCC 15+.
  `preserve_none` is clang 19+ only, so it goes behind a macro that
  expands to nothing elsewhere: correct, just more register traffic per
  jump. Is clang-or-GCC-15 an acceptable requirement for Rice's output?
- **Performance.** Frame slots live in memory instead of registers, and
  every return is an indirect jump (worse return-address prediction than
  `call`/`ret`). Expect a modest cost; measure at stage 5. If `rice_sp`
  as a global is a bottleneck, pass it as an argument and sync the global
  only at safe points.
- **Debuggability.** C backtraces stop showing the Curry call chain. The
  `--debug` frame-stack printer replaces it.
- **`catch`** (currently a stub) needs a handler frame kind: unwinding to
  it means popping frames until a handler frame is found. That's
  straightforward once frames exist, and much harder without them.
