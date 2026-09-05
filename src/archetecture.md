
Structure of Compiled Curry code
=================================

This describes the execution model the C runtime (`runtime/`) implements and
that ICurry-to-C codegen (`Rice.Codegen.C.*`, currently not compiling) has to
target. Sources: the runtime headers as they actually exist today
(`runtime/*.h`/`.c`), and old_rice's dissertation (`~/curry/old_rice/
dissertation.zip`, chapters 3/5/7 specifically), which is where the *design*
came from and, in several places, explains *why* the runtime looks the way it
does — knowledge that isn't recoverable from the C code alone. Where the
actual `runtime/` code has bugs or gaps relative to the design, that's called
out inline; see `STATUS.md` for the full bug list.

The curry graph is made up of Node objects.
A node consists of
  * missing: If this is a partial function, then it is the number of missing children.
             otherwise this is 0. For an `apply` node specifically, this holds
             the *negative* of the number of arguments applied — see
             "Higher-order functions and partial application" below.
  * nondet:  if this node depends on a non-deterministic value.
             All nodes start with a nondet of false (even choice nodes),
             but this can change as we evaluate the node.
  * symbol: a pointer to the symbol table which contains static information about the node.
  * children: an array of Node pointers.
              Each node has an array of 4 children, 
              but the last child is reserved to point to an array
              if a node has more than 3 children.

A symbol consists of 
  * `tag`: one of FAIL TAG, FUNCTION TAG, CHOICE TAG, FORWARD TAG, FREE TAG
           or a constructor tag
  * `arity`: the number of arguments the node takes
  * `name`: A string representation of the node used for debugging
  * `hnf`: a function pointer to a redution function
  * possiby `hnf_RET`: a reduction function for the if the node is the scrutinee
                       of a case expression
                       This is a useful optimization, but it really complicates the code.
                       **As of this writing, `hnf_RET` exists as a struct field
                       (`node.h`) but nothing in `runtime/` ever assigns it or
                       calls through it — case shortcutting is designed but
                       not implemented.** See "Case Shortcutting" below for
                       what actually has to exist to make this real.

Because this compiler supports unboxing, one of the children of a node
can be a literal long (for Int), unsigned long (for Char), or double (for Float).
The last child is also an array of `Node*`.
to support this, we have a field union:
```
typedef union field
{
    struct Node*  n; //normal node child
    union field*  a; //array child (for children[3])
    unsigned long c; //primitive character
    long          i; //primitive int
    double        f; //primitive float
} field ;
```
This means that `children` is not actually a `Node*[4]`, but really a `field[4]`
 

A Node can have up to 50 children,
However we want to have all nodes have a uniform layout.
So be default each node has 3 children.
any child after the third is stored in an auxillary array.
So, we can get the second child with
```n->children[1]```
but the fifth child is
```n->children[3].a[1]```

It's inconvenient to have to make this distinction,
so the runtime system has a macro
```child_at(node, index)```
that handles this.

There are 4 varients of this
```child_at_n(r, k)```
```child_at_i(r, k)```
```child_at_c(r, k)```
```child_at_f(r, k)```
```child_at_a(r, k)```
These are functionally the same as `child_at`, but give you back the field as a
`Node*`, `Int`, `Char`, `Float`, or field array respectively.


There is also child_at_v(node,index) for when the index is not a constant.
This is not recommended, because we actually have to do some computation at runtime,
but it is necessary sometimes.

**Known runtime bug**: `child_at_15` through `child_at_49` in `macros.h` are
shifted one array slot off from the correct pattern established by
`child_at_3`..`child_at_14`. Any node with 16+ children reads/writes the wrong
overflow-array slot.

Variables 
=========

Variables are all uniquely numbered starting with 2
Variable 0 is reserved as a reference to the root node.

Variable 1 is reserved as a reference to the scrutinee of a case.
This is used exclusively for the case shortcutting optimization
In case shortcutting, a variable with a negative index is used a variable
that is used as the scrutinee of a case, and nowhere else.

Evaluation: `hnf`, `nf`, and the collapsing-node loop
=======================================================

Every function `f` in the compiled program becomes a C function `f_hnf`
(historical name, from PAKCS) that reduces a node labeled `f` to **head
constructor form** (HCF) — evaluated enough to know its outermost
constructor, but not necessarily its children. `HNF(root)` is a macro/inline
wrapper (`runtime.h`) around `root.n->symbol->hnf(root)` — evaluation always
goes through the node's own symbol, never a direct call, since which function
actually runs depends on what the node currently *is*, and that changes as
evaluation proceeds.

A program runs until its `main` expression is reduced to **constructor normal
form** (CNF) — HCF, recursively, all the way down. This is `nf`'s job
(`runtime.c`): put `expr` in HCF, then recurse into each of its children (in
*reverse* order — see below for why arguments are stored reversed) putting
each one in CNF too, propagating a `FAIL` up through `fail_nf` if any child
failed.

The core of every `f_hnf` is a `while(true)` loop over a local `scrutinee`
variable (not the argument variable directly — see next paragraph), switching
on `TAG(scrutinee)`:

- `FUNCTION_TAG` → call `HNF(scrutinee)` to reduce it further, loop again.
- `CHOICE_TAG` → call `choose(scrutinee)`, loop again (see non-determinism below).
- `FORWARD_TAG` → `scrutinee = child_at(scrutinee, 0)`, loop again. This is
  the **collapsing-rule** mechanism: some reductions (choice, `apply`
  overapplication, unification) don't produce a real value, they just alias
  to another node. A `FORWARD` node is that alias. `forward_hnf` itself is a
  no-op (`runtime.c`) — nothing ever calls it; nodes only ever *become*
  `FORWARD` via `set_forward`, and evaluation dereferences the chain inline
  in the loop above, never by dispatching through the forward node's own
  `hnf`.
- `FAIL_TAG` → `fail(root)` and return.
- A constructor tag matching one of the case's branches → `set_<Ctr>(root,
  ...)` and return.

**Why a separate `scrutinee` local instead of updating the argument
variable in place**: if `x` forwards to `y`, and code later returns an
expression built from `x`, updating `x` to point past the forward chain
*before* that return would permanently rewrite the forwarding chain in the
graph — silently, from a codepath that has no business doing so. Keeping
`scrutinee` separate from the original variable means dereferencing forwards
locally for *this* evaluation's purposes doesn't leak into the graph.

Higher-order functions and partial application
=================================================

Every ordinary function/constructor node has a *fixed* arity known statically
— every `+` node has exactly 2 children, always. `apply` nodes are the
exception: an `apply` node's actual arity varies, and `missing` on an `apply`
node holds the *negative* of how many arguments it's been given (this is how
`apply_hnf` tells an `apply` node apart from an ordinary partial application,
both of which use the same `missing` field for different things).

**An `apply` node stores *its own* new arguments in reverse order** — `apply
f_k x` (applying a function missing `k` args to one more) needs to know
which child slot to put `x` in *within the apply node itself* before it's
copied over. If the apply node's own arguments were stored forward, that
slot would depend on the function's *total* arity, which the apply node
doesn't know in the general case. Stored in reverse, the apply node's own
newest argument always sits at a fixed low index, independent of the
function's arity — this part of the design is exactly as the dissertation
describes it and hasn't changed.

**But the target function's *own* node — what `f` actually points at, and
what `apply_hnf` copies arguments *into* — is a different, forward-laid-out
representation**, matching what `Rice.Codegen.C.ToH`'s generated `make_X`/
`set_X` produce (`Rice.Codegen.C.ToH`'s own comment on `setRealChildren` has
the full account): child 0 holds the first argument, child 1 the second, and
so on, with any still-missing arguments occupying the *last* `missing`
slots, in the same left-to-right order they'll eventually arrive in. This
has to be forward, not reversed, because it's also what `IVarAccess`/
`INodeAssign` read when a function's own body is running (`x1[0]`, `x1[1]`,
...) — and those indices come from the external `icurry` package, which
assumes plain forward indexing, not something Rice gets to choose.

Consequently, `apply_hnf`'s fill logic targets `f`'s symbol's `arity -
missing` (the first still-open slot, counting from the front, incrementing
as each new argument is consumed) rather than `missing - 1` (which would be
correct only if `f`'s own layout were reversed too, as it once was, before
`ToH` switched to forward storage). This mismatch was live for a while
without being noticed: a completely unapplied single-argument function
happens to make `arity - missing` and `missing - 1` agree (both 0 when
`arity = missing = 1`), which is exactly the shape of "pass a bare
known function as a `map`/`filter` argument" — the first real higher-order
code this project's own testing exercised. It only showed up once something
built a partial application with 2 or more arguments still missing (`add3 1
2`, or any curried, dictionary-passing typeclass default method — which is
how something as basic as `[a..b]`'s own `Ord`/`Enum` machinery reaches
it) — found by actually running old_rice's benchmark suite through the
finished Phase 1 compiler, not by inspection.

`apply_hnf` (the real one in `runtime.c`, not the simplified figure in the
dissertation — that version assumes all args sit in one array at
`children[3]` "to simplify the presentation"; the real one threads
`children[1]`/`children[2]`/`children[3].a` directly for efficiency) reduces
in two steps: first reduce the function child to a partial application
(looping on `f.n->missing <= 0`, i.e. "not yet under-applied" — same
FAIL/FUNCTION/CHOICE/FORWARD dispatch as any other hnf loop, plus a `FREE`
case that's a hard runtime error, since you can't apply an unbound variable).
Then:
- If under- or exactly-applied (`nargs <= missing`): copy `f`'s contents into
  `root`, move the `apply` node's own arguments into the newly-opened slots,
  and if that fills `f` exactly, evaluate it.
- If over-applied: copy `f`, fill it completely, reduce *that* to HCF, then
  build a fresh (smaller) `apply` node around the result and recurse.

Non-determinism: choice and free variables
=============================================

Two more tags exist for logic-language features: `CHOICE_TAG` and
`FREE_TAG`.

`choose(root)` (`runtime.c`) reduces a choice node. A choice node's third
child is a 0/1 marker (which side to take). `choose` snapshots the node
(`memcpy`), flips the marker in the snapshot, pushes `(root, snapshot,
choice-flag)` onto the backtracking stack (see below), then overwrites `root`
itself with a `FORWARD` to whichever side the marker currently selects —
choice is a **collapsing rule**, same mechanism as `apply` overapplication.

Free variables narrow lazily: when a case statement's scrutinee turns out to
be `FREE_TAG`, the generated code picks one possible constructor for the
scrutinee's type, instantiates its arguments as fresh free variables, and
pushes: (a) a rewrite that will restore the scrutinee back to a plain free
variable once this branch of the search is exhausted (`push_frame`), and (b)
one alternative-constructor choice per remaining constructor of that type
(`push_choice`).

**The backtracking stack is a single unified stack**, not separate
trail/choice-point stacks as in a classic WAM design. Every frame
(`FieldPair` in `stack.h`) is `(lhs, rhs, choice: bool)`. `undo()`
(`runtime.c`) pops frames and `memcpy`s `rhs` back over `lhs` — restoring
whatever that frame captured — and *keeps popping* past non-choice frames,
stopping (and returning `true`) only when it hits a frame marked
`choice=true`. This is what makes the stack do double duty: plain rewrite
frames (pushed by `save`/`save_copy`/`push_frame`, and by "fast
backtracking" below) exist purely to be undone on the way past; choice
frames (pushed by `push_choice`, and by `choose` — but *only* when taking the
left/first branch, `side==0`; a `choose` re-entered on the right branch
pushes a non-stopping frame instead, since there's no third alternative to
try) are where the search actually resumes with a different alternative.

Fast backtracking
====================

The naive approach pushes an undo-frame every time a node is rewritten,
whether or not the rewrite depended on anything non-deterministic — wasteful,
since a purely-deterministic reduction can never need to be undone. Instead,
every hnf loop tracks a local `nondet` boolean, OR'd in from `scrutinee.n
->nondet` on every iteration (and forced `true` whenever the loop passes
through a `CHOICE` or `FREE` node). Only if `nondet` ends up `true` does the
function push a rewrite frame before returning; otherwise it skips it
entirely. This is `push_node` in `runtime.h`, and it's gated by a compile-time
`TEST` macro (`NO_OPTS` vs `PUSH_NONDET` vs `EVAL_KNOWN_CALLS` vs
`EARLY_BACKTRACKING`) — the runtime has ablation switches for turning this
(and other optimizations) on/off, presumably built for the dissertation's own
benchmarking chapter. Don't be surprised to find `#if TEST == ...` guards
gating behavior in the runtime; they're intentional, not leftover debug code.

Boxed primitives, and the `Symbol.payload` design
====================================================

`Int`, `Char`, and `Float` are boxed — a node whose child holds the raw C
value — represented explicitly at the FlatCurry level (see "Unboxing" below)
specifically so the optimizer can reason about and remove boxes.

**Superseded design** (kept here for history — see `runtime.h`'s
`int_symbol`/`char_symbol`/`float_symbol`, planned for deletion in Phase 0):
all three shared the literal tag value `5` (`_int_TAG`/`_float_TAG`/
`_char_TAG`), so `switch(TAG(x))` couldn't distinguish them, and every
boxed-primitive node instead stored a sentinel in `children[1]`
(`INT_CTR`/`CHAR_CTR`/`FLOAT_CTR`, `-1`/`-2`/`-3`) that
`print_expr`/`print_final`/`ground_nf`/`nf`/`unify` all checked instead of
the tag. This worked, but meant the three boxed-primitive `Symbol`s were
hand-written directly into `runtime.h`, disconnected from the otherwise
fully general "every constructor gets a codegen-generated static `Symbol`"
story, and the payload discriminant was redundantly re-stamped into every
single node instance rather than being a fact about the constructor.

**Current design**: the discriminant belongs on the `Symbol`, not the node.
Every call site above (`print_expr`, `unify`, ...) already knows the node's
constructor identity by the time it needs to know "is this slot a raw
payload" — via `symbol->name` equality, `symbol->tag` equality, or
unconditionally — so the question is answerable once per *constructor*, not
once per *node*. Add a field to `Symbol` itself:

```c
typedef enum { PAYLOAD_NONE, PAYLOAD_INT, PAYLOAD_CHAR, PAYLOAD_FLOAT } Payload;

typedef struct
{
    const unsigned char tag;
    const unsigned int  arity;
    const char*         name;
    const Payload       payload;
    void (*hnf)(union field);
    struct Node* (*hnf_RET)(struct Node*);
} Symbol;
```

Ordinary constructors get `.payload = PAYLOAD_NONE` from the same codegen
path that already emits `.tag`/`.arity`/`.name` for them. `Prelude.Int`/
`Char`/`Float`'s boxes (`Rice.Transform.Unbox`'s `boxType`, itself an
ordinary single-constructor type by the time codegen sees it) get
`.payload = PAYLOAD_INT`/`PAYLOAD_CHAR`/`PAYLOAD_FLOAT` set at that same call
site — no separate hand-maintained runtime-side representation at all.
`make_int`/`set_int`/etc. and the three hardcoded `Symbol`s in `runtime.h`
are deleted outright; codegen's own `make__int`/`set__int` (`Compile.
PrimOps`) become the only representation, generated automatically like
everything else. Every call site collapses to reading `symbol->payload`
instead of the `children[1]` sentinel — `unify`'s old
`FLOAT_CTR <= child_at_i(x,1) && child_at_i(x,1) <= INT_CTR` range check
(quietly relying on `-1,-2,-3` being contiguous) becomes a plain
`payload != PAYLOAD_NONE`.

**Planned generalization, for unboxed fields + GC (not yet implemented):**
right now `payload` describes the *whole* constructor (it only ever applies
to an arity-1 wrapper with nothing else in it). The natural generalization,
once nodes can hold a *mix* of boxed and unboxed children — either a future
multi-field-unboxing pass, or a tracing garbage collector that needs to know
which child slots are real `Node*` to follow and which are opaque scalars to
skip — is to make `payload` **per child slot** rather than per constructor:
`const Payload payload[4]` (matching `children[4]`), one tag per slot,
`PAYLOAD_NONE` there meaning "this slot is a real `Node*`" rather than "this
constructor has no payload." That's a strict generalization of the current
scalar field (today's single-payload wrapper types are just the arity-1 case
of the array, `{PAYLOAD_INT}` and friends), and it directly gives a GC's mark
phase what it needs — "is `children[i]` a pointer" — without a separate
mechanism. If a packed pointer/non-pointer bitmask ever turns out to matter
for a hot mark loop (fewer memory accesses than walking the array), it's
mechanically derivable from the same per-constructor array
(`payload[i] != PAYLOAD_NONE`) at codegen time — start with the array, since
it's strictly more informative and the bitmask is a pure derived view of it,
not a separate design.

Unboxing (design summary — see `Rice.Transform.Unbox` for Rice's actual pass)
================================================================================

Three source-level changes make unboxing possible at all:
1. Every literal becomes a boxed constructor application: `5` becomes `Int
   5`.
2. Every `case` on a value that's *actually* a primitive gets wrapped: `case
   x of {0 -> e0; 1 -> e1}` becomes `case x of {Int x_p -> case x_p of {0 ->
   e0; 1 -> e1}; 0 -> <dummy>; 1 -> <dummy>}` — the outer case unboxes, the
   inner case (on the now-genuinely-primitive `x_p`) dispatches. The dummy
   branches exist purely so a free-variable scrutinee (narrowed against the
   *outer* case) knows what values it could take.
3. Primitive operations (`+`, `<=`, ...) get redefined to unbox both
   operands, compute with a genuine primitive op (`pl_p`, `le_p`, ...,
   compiled straight to a C operator), and rebox the result.

On top of that: `pcase` is a dedicated construct for a condition that's
*already* known to be primitive-typed and deterministic (only `eq_p`/`le_p`
comparisons on primitive values qualify — these are the *only* two primitive
relational operators; everything else, `<`, `>=`, etc., desugars to
combinations of `eq_p`/`le_p`/`not`) — it compiles straight to a C `if`, no
node, no tag check, no backtracking-stack interaction, because a comparison
between two already-unboxed primitives cannot be non-deterministic.

Strictness analysis (simple, syntactic, iterated-to-fixpoint over a
function's own body — start every parameter strict, relax based on which
parameters are used outside every case branch or as a non-strict argument)
then licenses a worker/wrapper split: the wrapper unboxes its arguments and
calls a `#worker` function that takes genuinely-unboxed primitives as
parameters and never constructs a box for an intermediate result at all. This
is what turns e.g. `fib` from allocating 5 nodes per call down to 2.

Case Shortcutting (`RET`)
============================

case shortcutting is a very simple optimization in Haskell,
but turns out to be obnoxious in Curry.
The idea is
case x || y of
  True -> ...
  False -> ...

I don't really need the node for x || y.
I just need the result, So I don't want to construct this node.
The solution that I've come up with is to have a static node called RET (for return).
I'll put the arguments in RET, and I can look at RET's tag after I evaluate it.
This works because I never have partially overlapping of case expressions.
So I never have a case where I have RET representing two different expressions at the same time.

This would be great, except for the fact that the scrutinee of a case might be non-deterministic.
If that's the case, I need to put _something_ on the backtracking stack.

**This is the part that's easy to get wrong, and the dissertation
(chapter 7) documents three successive failed attempts before landing on the
real design** — worth knowing the failure modes, not just the final answer,
because they're exactly the bugs a first implementation attempt will hit:

1. **Naive**: store the value directly in the static `RET` node, dispatch
   through its `hnf` as normal. Works for purely deterministic code, but if
   `RET` is non-deterministic, the rewrite frame pushed onto the backtracking
   stack ends up pointing *at* `RET` — which will almost certainly have been
   reused for something else by the time backtracking actually happens.
2. **Copy on backtrack**: when non-deterministic, `memcpy` `RET` into a fresh
   heap node and push *that* instead. Better, but still broken: (a) if `RET`
   is itself a `FORWARD` node, the thing it forwards *to* might also be
   non-deterministic without `RET` itself looking that way yet; (b) evaluating
   whatever `RET` forwards to can itself reuse `RET` *before* the copy
   happens, losing the very information being copied; (c) if the *original*
   expression (not something `RET` forwards to) was what got non-deterministically
   stored in `RET`, `RET` still ends up as the left-hand side of a pushed
   rewrite — exactly what this was trying to avoid.
3. **The real design**: give every function `f` that can appear as a `RET`
   scrutinee a *third* generated function, `f_RET_hnf(Node* backup)`, taking
   an explicit `backup` node instead of implicitly using `root`/`RET`. It
   returns `backup` (allocating it lazily, on first actual need, if it was
   passed `NULL`) — filled in with `RET`'s pre-reduction contents *only* if
   the reduction turns out to be non-deterministic, left untouched (still
   `NULL`) otherwise. Both caller and callee now agree on a single
   `backup` node that: is a genuine local variable, immune to `RET` being
   reused mid-evaluation; is only ever allocated when something actually
   needs to survive on the backtracking stack; and is threaded through
   nested `RET`-evaluations (a case scrutinee reducing another `RET`-eligible
   call reducing another...) so a whole chain of otherwise-node-free
   evaluation shares exactly one backup allocation, only if and when
   non-determinism ever actually shows up in that chain.

The payoff is real and not incremental: for a function like `fib`, the fully
optimized version (unboxing + worker/wrapper + shortcutting) allocates *zero*
heap memory for its recursive calls — a program that would otherwise need
exponential heap space runs in constant space, with only a fixed static node
allocated once at startup. `fib` stays exponential-*time*, but the removed
allocation pressure is a difference in kind, not degree.

**What this requires from codegen that doesn't exist yet**: a per-function
`f_RET_hnf` variant (beyond the plain `f_hnf`) for every function that can
occur as the scrutinee of a case whose result is used nowhere else; the
compiler has to identify that shape (a `Let`-bound variable used exactly once,
as a case scrutinee) — this is exactly the mark old_rice's own dissertation
describes as "marking every node only used as the scrutinee," a
whole-function-body analysis, not a local peephole rule. Nothing in Rice's
current `Rice.Optimize.Inline`/`FunTable` does this marking yet — it's new
work, not a fix to something partially there.

ICurry — the bridge to C
============================

ICurry sits between (optimized) FlatCurry and C. Its abstract syntax
(`ICurry.Types` in this repo, matching the design below):

```
p         =>  (vec t) (vec f)               program
t         =>  vec C                         datatype
f         =>  name = b                      function
b         =>  vec d                         block
              vec a
              s  
d         =>  declare x                     variable declaration
          |   declfree x                    free variable declaration
a         =>  v = e
s         =>  return e                      return statement
          |   EXEMPT                        failure
          |   case x of                     case statement
                   vec (C -> b)
e         =>  v                             variable expression
          |   NODE(l,vec e)                 node creation
          |   e_1 ? e_2                     choice expression
v         =>  x                             local variable
          |   v[i]                          variable access
          |   ROOT                          root variable
l         =>  C_k                           constructor label
          |   f_k                           function label
```

Every `let`/`case` from FlatCurry becomes explicit declarations + statements;
mutually-recursive bindings are split into a declare-then-fill-in-pointers
pair (so cyclic graphs can be built at all). Each function compiles to one
block: declarations, assignments, then exactly one terminating statement
(`return`, `EXEMPT`, or a `case`). A `case`'s branches are themselves nested
blocks. FlatCurry → ICurry is close to mechanical *given* the FlatCurry is
already in "canonical form" (no `let`/`case` nested inside a function
application, every `case` has a branch for every constructor — see
`Rice.Optimize`'s pre/post-processing for the equivalent canonicalization
Rice already does).

ICurry → C, in outline (see old_rice's dissertation chapter 5 for the full
syntax-directed translation this is condensed from):
- Each function `f = b` becomes `void f_hnf(field root) { <block b> }`.
- Each `declare x` becomes `field v_x;`; `declfree x` becomes `field v_x =
  free_var();`.
- Each assignment `x = e` becomes `v_x = <build e>;`; `x[i] = e` becomes
  `child_at(v_x, i) = <build e>;`.
- `return e` sets `root` from `e` (`set_forward` for a bare variable,
  `set_<Ctr>`/`set_<f>` for a node, `set_choice` for `e1 ? e2`) and returns.
- `EXEMPT` calls `fail(root)` and returns.
- A `case` compiles to exactly the `while(true)` / `switch(TAG(scrutinee))`
  loop shown above, with one addition needed only for codegen bookkeeping: at
  every point a rewrite might need pushing onto the backtracking stack (a
  `FAIL` branch, or a constructor branch, when `nondet` is set), codegen
  needs a `save(root, make_<f-at-this-case-position>(<free vars of the
  rest of the body>))` call — `f-at-this-case-position` names a *new*
  function generated for exactly this one case's continuation, parameterized
  by whatever free variables the surrounding body still needs. This is the
  concrete mechanism `Rice.Codegen.C.ToC`/`ToH` need to implement and don't
  yet (see `STATUS.md`).
- Node construction has a "make" (`Node* -> allocate a new node`, used from
  argument-position subexpressions) and a "set" (`existing node -> overwrite
  it`, used for the statement setting `root` itself) variant of each
  operation, mirroring the `make_X`/`set_X` pairs already present throughout
  `runtime.h` for every builtin tag.

Deforestation (brief — see dissertation chapter 7 for the full development)
================================================================================

A separate, source-level (not runtime) optimization for removing intermediate
lists in pipelines like `sum . filter isPrime . enumFromTo 2`, based on
`foldr`/`build` short-cut deforestation. The naive version doesn't fire in
Rice's inliner because it needs list-transforming functions like `filter`
written as literally `build (\c n -> foldr ... )` — a lambda Rice's inliner
(deliberately) never inlines. old_rice's fix was a purpose-built combinator,
`build_fold`, that composes with itself and with plain `build`/`foldr`
without needing lambda inlining at all — see `Optimize.Inline`'s `deforest`
rule in old_rice (`run_deforest`-gated) for the concrete rewrite rules,
should this become relevant again.
