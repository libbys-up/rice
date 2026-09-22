#ifndef RUNTIME_H
#define RUNTIME_H

#include <stdlib.h>
#include "node.h"
#include "macros.h"
#include "stack.h"
#include "debug.h"
#include "memory.h"
#include "prim.h"

#define FAIL_TAG     0
#define FUNCTION_TAG 1
#define CHOICE_TAG   2
#define FORWARD_TAG  3
#define FREE_TAG     4

// These need to be defines because I do tricky name concatenation.
// child_at(r,k) get the kth child of a node where k is a constant
// child_at_n same a child_at, but returns Node*
// child_at_i same a child_at, but returns long (Int)
// child_at_f same a child_at, but returns double (Float)
// child_at_c same a child_at, but returns unsigned long (Char)
// child_at_a same a child_at, but returns field*
// child_at_v same a child_at for variable k

#define child_at(r, k) child_at_##k(r.n)
#define child_at_n(r, k) child_at_##k(r.n).n
#define child_at_i(r, k) child_at_##k(r.n).i
#define child_at_c(r, k) child_at_##k(r.n).c
#define child_at_f(r, k) child_at_##k(r.n).f
#define child_at_a(r, k) child_at_##k(r.n).a
#define child_at_v(r, i) ((i) < 3 ? r.n->children[i] : r.n->children[3].a[(i)-3])
// child_at_v(r,i) is a ternary of two `union field` *values*.
// This is never an lvalue in C
// (unlike C++, `?:` doesn't yield one even when both branches are lvalues),
// so `child_at_v(r,i) = v` doesn't compile.
// set_child_at needs its own, pointer-typed ternary to dereference and assign through.
#define set_child_at(r, i, v) (*((i) < 3 ? &r.n->children[i] : &r.n->children[3].a[(i)-3]) = (v))



__attribute__((always_inline)) 
static inline unsigned char TAG(union field root)
{
    return root.n->symbol->tag;
}
// `forward_hnf` is a deliberate no-op (archetecture.md's "FORWARD_TAG
// collapsing" design: never mutate the original reference in here, leave
// following the chain to whoever's consuming the value, so a chain is
// never illegally compressed mid-walk) -- so a single `.hnf` call can
// leave `root` pointing at a FORWARD_TAG node instead of a real one.
// Every consumer that needs the actual resolved value handles this in its
// own loop, with its own reassignable local: a case's own dispatch loop
// (`case FORWARD_TAG: scrutinee = child_at(scrutinee,0); break;`,
// Rice.Codegen.C.ToC's generated code -- and, since that loop is the one
// place the ICurry block's later `IVarAccess`/`INodeAssign` references
// keep reading from, it also writes the fully-resolved value back into
// the *original* scrutinee variable once resolution finishes, not just
// its own loop-local copy -- see `writeBack` there) and apply_hnf's own
// while loop below both already do this. HNF itself deliberately stays a
// single, non-looping `.hnf` call: a version that resolved all the way
// through internally and returned where it landed was tried and reverted
// -- it broke nf_all's own backtracking loop, which depends on repeatedly
// re-examining the *same* top-level node object undo() restores by
// address; chasing straight through to a downstream value once loses
// that identity, and the second exploration silently re-inspects a value
// that's already fully reduced instead of the (undo-restored) choice
// point.
__attribute__((always_inline))
static inline void HNF(union field root)
{
    return root.n->symbol->hnf(root);
}



// The backtracking optimizations from src/backtracking-optimizations.md,
// each an independent compile-time 0/1 flag (settable via -D on the build
// command, e.g. -DOPT_EPOCH_TRAIL=0) rather than one ordinal level, since
// they're mostly independent of each other and need a real factorial
// comparison, not a linear one. Defaults are the validated-sound,
// safe-to-ship set; #2/#4/#5 default off because they aren't validated yet
// (#2 -- OPT_TAIL_JUMP -- is implemented, just not yet measured for either
// throughput or the specific thing it exists to guarantee: that a deep
// tail-recursive Curry function genuinely can't overflow the C stack,
// independent of what the C compiler's own optimizer decides to do).
#ifndef OPT_NONDET_TRAIL
#define OPT_NONDET_TRAIL 1
#endif
#ifndef OPT_TAIL_JUMP
#define OPT_TAIL_JUMP 0
#endif
#ifndef OPT_SCOPED_BACKTRACK
#define OPT_SCOPED_BACKTRACK 1
#endif
#ifndef OPT_COPY_COLLAPSE
#define OPT_COPY_COLLAPSE 0
#endif
#ifndef OPT_EPOCH_TRAIL
#define OPT_EPOCH_TRAIL 0
#endif

// backtracking-optimizations.md's #2, the trampolined half: `Rice.Codegen.
// C.ToC`'s generated `_hnf` bodies call this (as `TAIL_DISPATCH(g_hnf,
// root)`) instead of writing `g_hnf(root)` directly, right after building
// the call node for a tail-position call to `g` -- the *only* difference
// between the two `#if` branches is whether that call actually happens
// here or is left for something else to notice `root` is still
// FUNCTION_TAG and redispatch. Off (default): identical to today,
// `hnf_fn(root)` runs immediately, same as `HNF` -- correct only as far as
// the C compiler actually eliminates the resulting sibling call, exactly
// the caveat backtracking-optimizations.md's #2 section describes. On:
// does nothing here at all -- `root` is left exactly as `set_X` built it
// (a fresh FUNCTION_TAG node, `hnf_fn` is that node's own `symbol->hnf`),
// and it's up to whichever loop consumes `root` next to call it -- see
// HNF_SETTLE below for genuine "I need a real value here" consumers, and
// this file's own top and `apply_hnf` (runtime.c) for the two other
// places already structured as a loop that catches this for free.
// `hnf_fn` is always a statically-known function name here (Rice's own
// codegen already computed it, at Curry-compile time, as the string
// `mangle(f) ++ "_hnf"`), so no token-pasting is needed -- just pass it
// straight through.
#if OPT_TAIL_JUMP
#define TAIL_DISPATCH(hnf_fn, root) ((void)0)
#else
#define TAIL_DISPATCH(hnf_fn, root) hnf_fn(root)
#endif

// Same idea as TAIL_DISPATCH, for the two spots (apply_hnf, runtime.c)
// where the next dispatch isn't a statically-known function -- it's
// whatever `root.n->symbol->hnf` happens to be once `apply_hnf` has
// resolved `root` down to a fully-applied function -- so this takes the
// node itself rather than a function name.
#if OPT_TAIL_JUMP
#define TAIL_DISPATCH_PTR(root) ((void)0)
#else
#define TAIL_DISPATCH_PTR(root) (root.n->symbol->hnf(root))
#endif

// The other half of #2: a genuine trampoline *consumer*, for the places
// that need `root` actually settled right here -- not just "whatever's
// cheapest" -- because they're about to inspect its tag or fields
// directly (nf/ground_nf, and a handful of hand-written Prelude
// primitives -- bindIO, cond, prim_ioError, strictApply's `$!` case --
// that do the same). Repeatedly redispatches while `root` is still a
// pending call rather than trusting one `.hnf` call to reach WHNF, the
// way a plain `HNF` does. This is deliberately narrower than making HNF
// itself loop: HNF's own doc comment above explains why it must stay a
// single, non-looping call for FORWARD_TAG chains (nf_all's backtracking
// loop depends on that); this only ever loops on FUNCTION_TAG, never
// chases FORWARD_TAG, so it doesn't reopen that problem. When
// OPT_TAIL_JUMP is off this degenerates to exactly one call, identical to
// HNF.
//
// do/while, not while: `.hnf` must run at least once unconditionally,
// same as HNF itself -- most callers here don't already know root is
// FUNCTION_TAG (unlike apply_hnf's own resolution loop, which does).
// A plain `while(TAG(root)==FUNCTION_TAG)` skips the call entirely for
// anything that *isn't* already FUNCTION_TAG -- CHOICE_TAG above all,
// which is the normal case for a value nf/ground_nf haven't looked at
// yet -- silently never running choose() at all. Caught by actually
// running the test suite under OPT_TAIL_JUMP=1: `main = A ? B ? C`
// printed the raw, never-`choose()`d `?(B, A)` node instead of "A".
__attribute__((always_inline))
static inline void HNF_SETTLE(union field root)
{
#if OPT_TAIL_JUMP
    do
    {
        root.n->symbol->hnf(root);
    } while (TAG(root) == FUNCTION_TAG);
#else
    root.n->symbol->hnf(root);
#endif
}

// backtracking-optimizations.md's #3, generalized from lazy_unify_step
// (prelude.c, the original, hand-written instance of this pattern) to
// every generated `_hnf` function: SCOPED_CUTOFF() records the trail
// stack's height once, at function entry (Rice.Codegen.C.ToC's
// showBody), before anything this function does could have pushed
// anything. SCOPED_RETRY(scrutinee_var, orig_var), used wherever a
// case's scrutinee reaches FAIL_TAG or an unhandled (IExempt)
// constructor, tries undo(_cutoff) *before* ever touching `root` --
// undo() only walks the trail stack, so it doesn't need root mutated
// first, and if it finds nothing to flip, the caller falls through to
// today's unconditional fail(root) exactly as before. If it *does* find
// and flip a choice point, resetting scrutinee_var back to orig_var
// (Rice.Codegen.C.ToC re-emits the exact same `scrutinee = v;` the
// case's own dispatch loop already starts with) and `continue`ing lets
// that same while(true) loop re-read whatever undo restored -- CHOICE_TAG
// or FREE_TAG again, in the common case where the flipped choice point
// was the scrutinee's own resolution (choose()/narrowing always trail
// unconditionally), handled by cases the loop already has. No new
// recursion: if the flipped choice was instead buried inside whatever
// the scrutinee's own FUNCTION_TAG call did internally, re-reading lands
// back on FUNCTION_TAG, redispatched by the loop's own already-present
// `case FUNCTION_TAG: HNF(scrutinee); break;` -- exactly the same
// "ordinary HNF call" every case scrutinee already goes through
// regardless of this optimization, not a new risk it introduces.
//
// Deliberately narrower than this could be: a FAIL_TAG/IExempt reached
// with no enclosing case at all (a function that's unconditionally
// undefined) has no scrutinee to reset and falls through to plain
// fail(root) unchanged -- there's no local choice *this* function could
// have created to retry against. Same for ICaseLit (Rice.Codegen.C.ToC's
// showLitCase): its own scrutinee is already an extracted raw scalar by
// the time it's compared, not a `field` undo can restore in place, so
// scoped retry isn't wired up there yet.
#if OPT_SCOPED_BACKTRACK
#define SCOPED_CUTOFF() int _cutoff = size(bt_stack)
#define SCOPED_RETRY(scrutinee_var, orig_var) \
  if (undo(_cutoff)) { scrutinee_var = orig_var; continue; }
// SCOPED_RESAVE(nondet_var, root_node): used right after a SCOPED_RETRY that
// failed to find anything to flip, immediately before the `fail(root)` that
// follows. An unhandled (IExempt) case sits *inside* a constructor branch,
// and showConsBranch's prologue has already done `if(nondet) save_copy(root)`
// by then -- but a failed retry's undo(_cutoff) pops that very frame (it's
// the topmost one in scope) and restores `root`, so without re-saving,
// `fail(root)` would overwrite `root` with no trail record and later global
// backtracking could never restore it. (The FAIL_TAG path doesn't need this:
// its SCOPED_RETRY runs *before* its own save_copy.) With scoped retry off
// the prologue's save is still on the trail, so this is a no-op then.
#define SCOPED_RESAVE(nondet_var, root_node) \
  if (nondet_var) { save_copy(root_node); }
#else
#define SCOPED_CUTOFF() ((void)0)
#define SCOPED_RETRY(scrutinee_var, orig_var) ((void)0)
#define SCOPED_RESAVE(nondet_var, root_node) ((void)0)
#endif

// The backtracking stack can be used pretty much anywhere, so it almost has
// to be a global variable.  The only alternative is to pass it to every
// single function.
extern Stack* bt_stack;

// Used to print out the total number of memory allocations
// (see alloc() in memory.h).
extern unsigned long mem;

// backtracking-optimizations.md's #5: the active choice point's own
// stamp, incremented once per choice point created (choose()/
// push_choice(), runtime.c), compared against a node's own `epoch`
// (node.h, conditional on the same flag) to decide whether it's provably
// younger than the search's current position and so needs no trail frame.
// Declared unconditionally (not just under OPT_EPOCH_TRAIL) so stack.c
// can always snapshot/restore it across a push/pop without its own code
// needing to know whether #5 is actually enabled -- when it's off nothing
// ever increments this past 0, making that snapshot/restore a harmless
// no-op rather than something to conditionally compile too.
extern unsigned int current_epoch;

static inline void fail(union field root);
union field copy(union field node);
void save_copy(union field n);

// push a node on the backtracking stack -- unconditionally under
// !OPT_NONDET_TRAIL, only when `nondet` is set otherwise (see
// backtracking-optimizations.md's #1: a node whose reduction never
// touched a CHOICE/FREE node produces the same result regardless of which
// alternative an *enclosing* choice takes, so there's nothing for
// backtracking to ever need to undo about it). Under OPT_EPOCH_TRAIL,
// #1's criterion is further tightened per #5: even a nondet node needs no
// trail frame if it was allocated *after* the active choice point --
// backtracking past that choice point already makes it unreachable on its
// own, the same way WAM's own trail condition skips anything younger than
// the top choice point rather than relying on a bump-pointer heap reset.
#if OPT_NONDET_TRAIL
__attribute__((always_inline))
static inline void push_node(union field root, bool nondet)
{
    root.n->nondet = nondet;
#if OPT_EPOCH_TRAIL
    if(nondet && root.n->epoch < current_epoch)
#else
    if(nondet)
#endif
    {
        stack_push(bt_stack, root, copy(root), false);
    }
}
#else
__attribute__((always_inline))
static inline void push_node(union field root, bool nondet)
{
    root.n->nondet = nondet;
    stack_push(bt_stack, root, copy(root), false);
}
#endif

// when reducing a node to normal form, if the child is FAIL, then the root
// should also be FAIL.
__attribute__((always_inline))
static inline void fail_nf(union field child, union field root)
{
    root.n->nondet |= child.n->nondet;
    save_copy(root);
    fail(root);
}


////////////////////////////////////////////////
// Functions to simplify setting nodes.
////////////////////////////////////////////////

static inline __attribute__((always_inline))
void set0(union field root, Symbol* sym)
{
    root.n->missing = 0;
    root.n->nondet = false;
    root.n->symbol = sym;
    root.n->children[0].n = NULL;
    root.n->children[1].n = NULL;
    root.n->children[2].n = NULL;
    root.n->children[3].a = NULL;
}
static inline __attribute__((always_inline))
void set1(union field root, Symbol* sym, union field v0)
{
    root.n->missing = 0;
    root.n->nondet = false;
    root.n->symbol = sym;
    root.n->children[0] = v0;
    root.n->children[1].n = NULL;
    root.n->children[2].n = NULL;
    root.n->children[3].a = NULL;
}

static inline __attribute__((always_inline))
void set2(union field root, Symbol* sym, union field v0, union field v1)
{
    root.n->missing = 0;
    root.n->nondet = false;
    root.n->symbol = sym;
    root.n->children[0] = v0;
    root.n->children[1] = v1;
    root.n->children[2].n = NULL;
    root.n->children[3].a = NULL;
}

static inline __attribute__((always_inline))
void set3(union field root, Symbol* sym, union field v0, union field v1, union field v2)
{
    root.n->missing = 0;
    root.n->nondet = false;
    root.n->symbol = sym;
    root.n->children[0] = v0;
    root.n->children[1] = v1;
    root.n->children[2] = v2;
    root.n->children[3].a = NULL;
}



/////////////////////////////////////////////////
/// hnf/symbol definitions
/////////////////////////////////////////////////

void CTR_hnf(union field root);
void choice_hnf(union field root);
void apply_hnf(union field root);
void forward_hnf(union field root);

// set a free variable (I think)
// TODO: figure out if I'm right about this.
void set_free_constructor(union field n, Symbol* sym);

union field copy(union field node);
union field set_copy(union field new_node, union field node);
union field set_copy_free(union field new_node, union field node);

void save_copy(union field n);
void save(union field n, union field saved);

void push_choice(union field left, union field right);
void push_frame(union field left, union field right);
void choose(union field root);

bool undo(int cutoff);

void print_stack(Stack* s);
void print_frame(FieldPair* f);
void print_expr(union field n);
void print_final(union field n);
void print_tuple(union field n, int i);
void print_list(union field n);

void nf(union field expr);
void ground_nf(union field expr);
void nf_all(union field expr);

void error(char* msg, union field expr);

// --stack-size (Rice.Codegen.C.ToC's writeMain, runtime.c's own doc
// comment on the definitions): raise the process's own stack rlimit, up
// to `bytes` or the OS's hard limit, whichever is smaller.
void set_stack_size(unsigned long bytes);
void set_stack_size_max(void);

// functions for manipulating curry strings
union field toCurryString(char* str);
void setCurryString(union field root, char* str);
char* toCStr(union field string);


static Symbol fail_symbol    = { .tag = FAIL_TAG,     .arity = 0, .name = "FAIL",    .hnf = &CTR_hnf };
static Symbol choice_symbol  = { .tag = CHOICE_TAG,   .arity = 2, .name = "?",       .hnf = &choice_hnf };
static Symbol forward_symbol = { .tag = FORWARD_TAG,  .arity = 1, .name = "->",      .hnf = &forward_hnf };
static Symbol free_symbol    = { .tag = FREE_TAG,     .arity = 0, .name = "free",    .hnf = &CTR_hnf };
static Symbol apply_symbol   = { .tag = FUNCTION_TAG, .arity = 0, .name = "apply",   .hnf = &apply_hnf };

// Placeholder for case shortcutting (archetecture.md's "Case Shortcutting
// (RET)" section, Phase 2 -- not implemented yet). Nothing calls
// make_restore currently, so this only needs to exist for the file to
// compile; its actual fields don't need to be correct until Phase 2 wires
// case shortcutting up for real.
static Symbol backup_symbol  = { .tag = FAIL_TAG,     .arity = 0, .name = "RET",     .hnf = &CTR_hnf };

// when I know I'm going to reduce an apply node, 
// I already have the number of arguments as part of the name.
// So, I just want these to pass through to apply_hnf.
// This is actually a potential chance for optimization in the future.
__attribute__((always_inline)) 
static inline void apply1_hnf(union field root) {apply_hnf(root);}
__attribute__((always_inline)) 
static inline void apply2_hnf(union field root) {apply_hnf(root);}
__attribute__((always_inline)) 
static inline void apply3_hnf(union field root) {apply_hnf(root);}


__attribute__((always_inline)) 
static inline Node* make_restore(Node* backup)
{
    if(!backup)
    {
        backup = (Node*)alloc(sizeof(Node));
        backup->symbol = &backup_symbol;
    }
    return backup;
}

__attribute__((always_inline)) 
static inline void fail(union field root)
{
    root.n->symbol = &fail_symbol;
    root.n->missing = 0;
    child_at_n(root, 0) = NULL;
    child_at_n(root, 1) = NULL;
    child_at_n(root, 2) = NULL;
    root.n->children[3].a = NULL;
}

__attribute__((always_inline)) 
static inline void set_choice(union field root, union field left, union field right)
{
    root.n->missing = 0;
    root.n->symbol = &choice_symbol;
    child_at(root,0) = left;
    child_at(root,1) = right;
    child_at(root,2).i = 0;
    root.n->children[3].a = NULL;
}

__attribute__((always_inline))
static inline void set_forward(union field root, union field child)
{
    root.n->missing = 0;
    root.n->symbol = &forward_symbol;
    child_at(root,0) = child;
    child_at_n(root,1) = NULL;
    child_at_n(root,2) = NULL;
    root.n->children[3].a = NULL;
}

// backtracking-optimizations.md's #4: at a "collapse point" -- a function
// body whose final value is just an already-existing node (`id x = x`, or
// a case branch returning one of its own bound sub-values unchanged) --
// set_forward's FORWARD_TAG indirection is only there so that if `child`
// later gets narrowed further (backtracking, unification), `root` sees it
// too. That indirection is unneeded, and strictly extra pointer-chasing
// for every future reader, when `child` is already a value nothing can
// narrow any further: something already in real HNF (not FUNCTION_TAG,
// which just means "not yet reduced") and not `nondet` (backtracking-
// optimizations.md's #1: `nondet` means some choice touched during its
// reduction might still get undone, so a copy taken now could go stale --
// only a target that's provably immune to that is safe to copy). In that
// case `root` can instead become a direct, independent copy of `child`'s
// own node -- readers see the real value straight away, no forward hop.
// CHOICE_TAG is excluded even though it's technically "resolved": a live
// choice node still has two live alternatives backtracking can flip
// between, so collapsing to it needs the same forwarding indirection a
// FUNCTION_TAG does, not a copy of whichever branch happened to run first.
// FREE_TAG is excluded for the same reason, and this one isn't caught by
// the `nondet` check alone: an as-yet-untouched free variable can have
// `nondet == false` (nothing has reduced it yet to set the flag), but
// it's still a placeholder, not a value -- unification binds it later by
// mutating/forwarding *that node's own address* in place, and a `root`
// that copied its (empty) content away earlier would never see the
// binding land.
__attribute__((always_inline))
static inline bool collapse_safe(union field target)
{
    unsigned char t = TAG(target);
    return t != FUNCTION_TAG && t != CHOICE_TAG && t != FREE_TAG && !target.n->nondet;
}

#if OPT_COPY_COLLAPSE
__attribute__((always_inline))
static inline void collapse(union field root, union field target)
{
    if (collapse_safe(target))
    {
        // `root.n->nondet` records *root's own* backtracking-relevant
        // history (e.g. showConsBranch's save_copy already having pushed
        // root's pre-collapse content to the trail moments earlier, which
        // sets it true right before this call) -- a fact about this
        // memory address, unrelated to whatever `target`'s own value
        // happens to be. set_copy's memcpy would otherwise stomp it with
        // `target.n->nondet` (always false here, per collapse_safe), the
        // same reasoning that already makes set_copy preserve the
        // destination's `epoch` across the copy rather than take the
        // source's.
        bool keep_nondet = root.n->nondet;
        set_copy(root, target);
        root.n->nondet = keep_nondet;
    }
    else
    {
        set_forward(root, target);
    }
}
#else
__attribute__((always_inline))
static inline void collapse(union field root, union field target)
{
    set_forward(root, target);
}
#endif

__attribute__((always_inline))
static inline union field make_forward(union field child)
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
#if OPT_EPOCH_TRAIL
    n.n->epoch = current_epoch;
#endif
    n.n->nondet = false;
    n.n->missing = 0;
    n.n->symbol = &forward_symbol;
    child_at(n, 0) = child;
    return n;
}

    __attribute__((always_inline))
static inline union field make_choice(union field left, union field right)
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
#if OPT_EPOCH_TRAIL
    n.n->epoch = current_epoch;
#endif
    n.n->nondet = false;
    n.n->missing = 0;
    n.n->symbol = &choice_symbol;
    child_at(n, 0) = left;
    child_at(n, 1) = right;
    child_at(n, 2).i = 0;
    return n;
}

__attribute__((always_inline))
static inline union field free_var()
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
#if OPT_EPOCH_TRAIL
    n.n->epoch = current_epoch;
#endif
    n.n->symbol = &free_symbol;
    return n;
}


////////////////////////////////////////////////////////////////////////
//
// Partial application
//
////////////////////////////////////////////////////////////////////////

//////////////////////////////////////
// app1
//////////////////////////////////////

__attribute__((always_inline)) 
static inline void set_apply1(union field root, union field f, union field v1)
{
    root.n->symbol = &apply_symbol;
    root.n->missing = -1;
    child_at(root,0) = f;
    child_at(root,1) = v1;
}

__attribute__((always_inline))
static inline union field make_apply1(union field f, union field v1)
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
#if OPT_EPOCH_TRAIL
    n.n->epoch = current_epoch;
#endif
    n.n->symbol = &apply_symbol;
    n.n->missing = -1;
    child_at(n,0) = f;
    child_at(n,1) = v1;
    return n;
}

__attribute__((always_inline)) 
static inline void set_apply2(union field root, union field f, union field v1, union field v2)
{
    root.n->symbol = &apply_symbol;
    root.n->missing = -2;
    child_at(root,0) = f;
    child_at(root,1) = v2;
    child_at(root,2) = v1;
}

__attribute__((always_inline))
static inline union field make_apply2(union field f, union field v1, union field v2)
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
#if OPT_EPOCH_TRAIL
    n.n->epoch = current_epoch;
#endif
    n.n->symbol = &apply_symbol;
    n.n->missing = -2;
    child_at(n,0) = f;
    child_at(n,1) = v2;
    child_at(n,2) = v1;
    return n;
}

__attribute__((always_inline)) 
static inline void set_apply3(union field root, union field f, union field v1, union field v2, union field v3)
{
    root.n->symbol = &apply_symbol;
    root.n->missing = -3;
    root.n->children[3].a = (union field*)alloc(sizeof(union field) * 1);
    child_at(root,0) = f;
    child_at(root,1) = v3;
    child_at(root,2) = v2;
    child_at(root,3) = v1;
}

__attribute__((always_inline))
static inline union field make_apply3(union field f, union field v1, union field v2, union field v3)
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
#if OPT_EPOCH_TRAIL
    n.n->epoch = current_epoch;
#endif
    n.n->symbol = &apply_symbol;
    n.n->missing = -3;
    n.n->children[3].a = (union field*)alloc(sizeof(union field) * 1);
    child_at(n,0) = f;
    child_at(n,1) = v3;
    child_at(n,2) = v2;
    child_at(n,3) = v1;
    return n;
}

#endif //RUNTIME_H
