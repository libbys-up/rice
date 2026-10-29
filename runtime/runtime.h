#ifndef RUNTIME_H
#define RUNTIME_H

#include <stdlib.h>
#include "node.h"
#include "macros.h"
#include "trail.h"
#include "debug.h"
#include "memory.h"
#include "prim.h"
#include "machine.h"
#include "gc.h"

/* Basic tags for the eval loops
 * Every node can be one of these tags
 *   * FAIL_TAG: a failed computation, trigger backtracking
 *   * FUNCTION_TAG: an unevaluated thunk
 *   * CHOICE_TAG: a ? b
 *   * FORWARD_TAG: (indirection) we had a collapsing rule.
 *                  like id x = x
 *                  But other nodes are pointing to the id node,
 *                  so something needs to be there
 *   * FREE_TAG: a free variable
 */
#define FAIL_TAG     0
#define FUNCTION_TAG 1
#define CHOICE_TAG   2
#define FORWARD_TAG  3
#define FREE_TAG     4

/* These need to be #defines because I do tricky name concatenation.
 * child_at(r,k) get the kth child of a node where k is a constant
 * child_at_n same a child_at, but returns Node*
 * child_at_i same a child_at, but returns long (Int)
 * child_at_f same a child_at, but returns double (Float)
 * child_at_c same a child_at, but returns unsigned long (Char)
 * child_at_a same a child_at, but returns field*
 */

#define child_at(r, k) child_at_##k(r.n)
#define child_at_n(r, k) child_at_##k(r.n).n
#define child_at_i(r, k) child_at_##k(r.n).i
#define child_at_c(r, k) child_at_##k(r.n).c
#define child_at_f(r, k) child_at_##k(r.n).f
#define child_at_a(r, k) child_at_##k(r.n).a

/* child_at_v is child_at for a variable index i.
 * This does computation at runtime, so use it only when you need to.
 * You can't assign through it; use set_child_at for that.
 */
static inline union field child_at_v(union field r, int i)
{
    if(i < 3)
    {
        return r.n->children[i];
    }
    return r.n->children[3].a[i - 3];
}

static inline void set_child_at(union field r, int i, union field v)
{
    if(i < 3)
    {
        r.n->children[i] = v;
    }
    else
    {
        r.n->children[3].a[i - 3] = v;
    }
}


/* How many of node n's children are filled in:
 * This is only relavant in a partial application (missing > 0)
 * so we need to count the last `missing` slots.
 */
static inline int filled_arity(union field n)
{
    int arity = (int)n.n->symbol->arity;
    if(n.n->missing > 0)
    {
        return arity - n.n->missing;
    }
    else
    {
        return arity;
    }
}

/* Debug check that a node's children match its symbol's reps (in node.h):
 * every filled R_PTR child must look like a node pointer.
 * We need to catch a raw value sitting in a pointer slot (this is catastrophic for GC)
 * On by default at DEBUG >= MED;
 * -DCHECK_LAYOUT=1 turns it on alone, without the debug trace output.
 */
#ifndef CHECK_LAYOUT
#define CHECK_LAYOUT (DEBUG >= MED)
#endif
void check_layout(union field n, bool allow_null, const char* where);

// Prints a field of the given rep: a raw value as a literal, a pointer as
// an expression (print_expr).
void print_field(union field v, FieldRep r);

/* If s is one of the primitive boxes (Prelude's Int/Char/Float),
 * which primitive it holds; R_PTR for every other symbol.
 * The constructor-tag check keeps a function with one
 * raw parameter (prim_putChar's thunk) from looking like a box.
 */
static inline FieldRep box_rep(const Symbol* s)
{
    if(s->tag > FREE_TAG && s->arity == 1)
    {
        return child_rep(s, 0);
    }
    else
    {
        return R_PTR;
    }
}



__attribute__((always_inline))
static inline unsigned char TAG(union field root)
{
    return root.n->symbol->tag;
}

/* Reduce root to head normal form with a single call to its hnf function.
 *
 * Be careful: root might still be a FORWARD node when this returns.
 * forward_hnf doesn't do anything, so it's up to the caller to chase forwards
 * (see settle below, or the case loops in the generated code).
 *
 * Don't make this loop until it finds a value.
 * nf_all keeps re-examining the same top-level node after undo() restores it,
 * and it needs that node's address, not wherever the forward chain ended up.
 */
__attribute__((always_inline))
static inline void HNF(union field root)
{
    eval_hnf(root);
}



/* The backtracking optimizations (developer's manual, "Making backtracking
 * cheaper"; the soundness arguments are in backtracking_proofs.md).
 * Each one is its own 0/1 flag so we can turn them on and off independently
 * (-DOPT_EPOCH_TRAIL=1 on the command line, or rice's RICE_CFLAGS).
 *  * OPT_NONDET_TRAIL (#1): only trail a rewrite if it read something nondeterministic.
 *  * OPT_SCOPED_BACKTRACK (#3): when a case fails, retry choices made since the case began first.
 *  * OPT_COPY_COLLAPSE (#4): collapse to a copy of a finished value instead of a FORWARD.
 *  * OPT_EPOCH_TRAIL (#5): don't trail nodes created after the last choice point.
 *  * OPT_PATH_COMPRESS: when a case reads a forward, retarget it past the
 *    deterministic forwards behind it (follow_forward below).
 *  * OPT_WRITE_BARRIER: stamp nodes built by a deterministic rewrite as old
 *    as the node they're built for (rewrite_stamp below).
 *    It's required when #1 and #5 are both on, and on by default then.
 * Every subset of these is proved to give the baseline's answers on a model
 * of the machine (backtracking_proofs.md), given the barrier when #1 and #5 are both on.
 * #4, #5 and path compression are off by default until we've measured them.
 *  * OPT_TAIL_DISPATCH (#2): a tail call jumps straight to the callee's code.
 *    Off, it goes through redispatch (runtime.c) instead, the way a
 *    trampoline would: check root's tag, then jump through root's symbol.
 *    Both are musttail jumps, so the C stack is the same either way;
 *    off only exists to measure what #2 saves.
 */
#ifndef OPT_NONDET_TRAIL
#define OPT_NONDET_TRAIL 1
#endif
#ifndef OPT_TAIL_DISPATCH
#define OPT_TAIL_DISPATCH 1
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
#ifndef OPT_PATH_COMPRESS
#define OPT_PATH_COMPRESS 0
#endif
#ifndef OPT_WRITE_BARRIER
#define OPT_WRITE_BARRIER (OPT_NONDET_TRAIL && OPT_EPOCH_TRAIL)
#endif

/* #1 and #5 are each sound alone, but not together without the barrier.
 * #1 leaves an old node's deterministic rewrite untrailed,
 * so it can end up pointing at a young node whose rewrite #5 didn't trail
 * (tests/programs/regressions/stale_apply.curry).
 * The barrier makes that young node look as old as the node it hangs from.
 * #5 without #1 is proved with the barrier off, so it's only on by default with both.
 */
// -DOPT_ALLOW_UNSOUND=1 builds the combination anyway,
// only to check that the regression tests catch it (stale_mk.curry and friends).
#if OPT_NONDET_TRAIL && OPT_EPOCH_TRAIL && !OPT_WRITE_BARRIER && !OPT_ALLOW_UNSOUND
#error "OPT_NONDET_TRAIL with OPT_EPOCH_TRAIL needs OPT_WRITE_BARRIER"
#endif
#if OPT_WRITE_BARRIER && !OPT_EPOCH_TRAIL
#error "OPT_WRITE_BARRIER only means something with OPT_EPOCH_TRAIL"
#endif

static inline field follow_forward(field r);

/* Counters for measuring the optimizations (tests/optbench.sh).
 * Build with -DOPT_STATS=1 and every run prints them to stderr when it ends
 * (print_opt_stats, runtime.c).  Without it, STAT(...) is nothing.
 */
#ifndef OPT_STATS
#define OPT_STATS 0
#endif
#if OPT_STATS
typedef struct
{
    unsigned long trail_decisions;      // rewrites that asked needs_trail
    unsigned long trailed_rewrites;     // ... and got a trail entry
    unsigned long skipped_nondet;       // ... and #1 said no
    unsigned long skipped_epoch;        // ... and #5 said no
    unsigned long barrier_lowered;      // nodes' stamps the barrier lowered (per rewrite)
    unsigned long lowered_nodes;        // nodes built with a lowered stamp
    unsigned long lowered_rewritten;    // those nodes that were ever rewritten
    unsigned long lowered_rewrites;     // later rewrites of those nodes
    unsigned long lowered_trailed;      // ... that got a trail entry
    unsigned long trail_pushes;         // every trail entry, of any kind
    unsigned long choice_points;        // trail entries undo() stops at
    unsigned long undos;                // calls to undo() that popped something
    unsigned long undo_restores;        // entries undo() copied back
    unsigned long scoped_retries;       // SCOPED_RETRYs tried (#3)
    unsigned long scoped_hits;          // ... that found a choice to flip
    unsigned long copy_collapses;       // collapses done as a copy (#4)
    unsigned long forward_collapses;    // collapses done as a FORWARD
    unsigned long forward_hops;         // FORWARD nodes followed by readers
    unsigned long compressions;         // forwards retargeted (path compression)
    unsigned long compress_hops_skipped;// hops those retargetings skipped
    unsigned long max_trail;            // the trail's high water mark
    unsigned long tail_calls;           // generated tail calls (TAIL_CALL)
} OptStats;
extern OptStats opt_stats;
#define STAT(name) (opt_stats.name++)

// A second bit in gc_bits, only in OPT_STATS builds: the barrier built this
// node with a stamp older than now (stamp_node), so we can count what its
// later rewrites cost.  The collector only reads and clears GC_TRAILED.
#define STAT_LOWERED 2
// ... and has been rewritten since.
#define STAT_REWRITTEN 4
#else
#define STAT(name) ((void)0)
#endif
void print_opt_stats(void);

/* Settle root to an actual value, for C code that isn't machine code
 * (strictApply's $!! and $##, prim_ioError, toCStr).
 * We chase FORWARD nodes and run `force` (usually eval_hnf) until we land on
 * something that isn't a FORWARD, FUNCTION, or CHOICE node.
 * That's a constructor, FAIL, or FREE.
 * Machine code uses settle_step and EVAL_OR_CONTINUE instead.
 *
 * We need the loop because one evaluation isn't enough:
 * an evaluation can leave a FORWARD behind (choose() always does),
 * and the forward can point at another unevaluated call.
 *
 * *nondet is OR'd into, not reset, the same as the nondet flag in a case loop.
 * We collect the flag from every node we pass through,
 * because the choice that made this nondeterministic is usually a node we passed,
 * not the node we end up on.
 * Pass NULL if you don't need it.
 */
static inline field settle(union field root, bool* nondet, void (*force)(field))
{
    // force() runs the machine, so a collection may move root.
    GC_ROOT(root);
    while(true)
    {
        if(nondet != NULL)
        {
            *nondet |= root.n->nondet;
        }
        unsigned char t = TAG(root);
        if(t == FORWARD_TAG)
        {
            root = follow_forward(root);
        }
        else if(t == FUNCTION_TAG || t == CHOICE_TAG)
        {
            force(root);
        }
        else
        {
            GC_UNROOT(1);
            return root;
        }
    }
}

/* settle() for machine code.
 * We chase FORWARD nodes in *x, collecting nondet the same way settle() does,
 * and report whether *x is settled (anything but FUNCTION or CHOICE).
 * If it isn't, the caller saves its state in its frame and jumps to x's code,
 * instead of making a nested call.  That's EVAL_OR_CONTINUE below.
 */
static inline bool settle_step(union field* x, bool* nondet)
{
    while(true)
    {
        *nondet |= x->n->nondet;
        unsigned char t = TAG(*x);
        if(t == FORWARD_TAG)
        {
            *x = follow_forward(*x);
        }
        else
        {
            return t != FUNCTION_TAG && t != CHOICE_TAG;
        }
    }
}

/* The evaluate-and-resume step of a runtime routine written for the machine.
 * If `x` still needs evaluating, save it and `nd` in the routine's frame
 * (slots xslot and ndslot) and jump to x's code.
 * When x is done, it returns into the routine's continuation,
 * and the first thing the continuation does is this same macro.
 * Once x is settled, we fall through.
 */
#define EVAL_OR_CONTINUE(x, xslot, nd, ndslot)              \
    do {                                                    \
        if(!settle_step(&(x), &(nd)))                       \
        {                                                   \
            SLOT(xslot) = (x);                              \
            SLOT(ndslot).i = (nd);                          \
            MUSTTAIL return (x).n->symbol->hnf((x), sp);    \
        }                                                   \
    } while(0)

/* Scoped backtracking (#3).
 * When a case in a generated function fails, we first try to undo choices
 * that were made since that case started, before failing root.
 *  * The cutoff is the trail's height when the case started, kept in a frame
 *    slot because a case block runs as its own C function.
 *    SCOPED_LOAD_CUTOFF(slot) names that slot; nothing is read until a retry.
 *    The cutoff is per case, not per function: the retry only redoes this case's dispatch,
 *    so it can't flip a choice that an enclosing case's dispatch read
 *    (backtracking_proofs.md, #3 rule 2; regressions/scoped_stale_dispatch.curry).
 *  * The cutoff is recorded lazily. SCOPED_MARK_CUTOFF goes first in the
 *    FUNCTION, CHOICE and FREE branches, the only ones that can push a choice.
 *    Until one runs, the trail can grow only by path compression's retargets
 *    in the FORWARD branch, which don't change what any node means, so the
 *    height then is as good a cutoff as the height at entry.
 *    The slot holds height + 1, or 0 (frame_push's zero) while unmarked.
 *    A case that never marked pushed no choice, so its retry has nothing to flip
 *    and is skipped. That way a deterministic case pays nothing for #3.
 *  * SCOPED_RETRY(scrutinee) is used where a case's scrutinee is FAIL
 *    or a constructor the case doesn't handle.
 *    If undo() finds a choice to flip, we reset the scrutinee to the case's
 *    original one (frame slot 1, which the loop never writes) and `continue`
 *    the case loop, which re-reads whatever undo() restored.
 *    Otherwise we fall through to the usual fail(root).
 *
 * SCOPED_RETRY can't use the do { ... } while(0) trick:
 * its `continue` is meant for the case loop, and inside a do-while it would
 * just jump out of the do-while.  The `else ((void)0)` keeps a following
 * `else` from attaching to our `if`.
 *
 * We don't retry in a function with no enclosing case (there's no scrutinee to reset),
 * or in a literal case (its scrutinee is a raw value, which undo() can't restore).
 */
#if OPT_SCOPED_BACKTRACK
#define SCOPED_LOAD_CUTOFF(n) enum { _cutslot = (n) }
#define SCOPED_MARK_CUTOFF() \
    (SLOT(_cutslot).i ? (void)0 : (void)(SLOT(_cutslot).i = trail_size(trail) + 1))
#define SCOPED_RETRY(scrutinee_var)                                  \
    STAT(scoped_retries);                                            \
    if(SLOT(_cutslot).i != 0 && undo((int)SLOT(_cutslot).i - 1))     \
    {                                                                \
        STAT(scoped_hits);                                           \
        scrutinee_var = SLOT(1);                                     \
        continue;                                                    \
    }                                                                \
    else ((void)0)

/* SCOPED_RESAVE goes right after a SCOPED_RETRY that didn't find anything,
 * just before the fail(root).
 * For an unhandled constructor, the branch has already trailed root.
 * But the failed retry's undo() popped that entry (it was the newest one in scope),
 * so we have to trail root again, or nothing could ever restore it.
 * With no cutoff marked the retry popped nothing, but we still trail:
 * the branch's entry was gated on nondet, and rule 1 below needs more.
 *
 * SCOPED_FAIL_TRAIL is the trail for the FAIL case's fail(root),
 * which runs after its SCOPED_RETRY.
 *
 * Both always trail, whatever nondet says (backtracking_proofs.md, #3 rule 1).
 * The proof of #3 needs the next undo to restore a scope's fail write,
 * and the flag here is only this case's own, which can be false
 * while the case's root depends on a choice (regressions/scoped_nested_nd.curry).
 */
#define SCOPED_RESAVE(root_node) save_copy(root_node)
#define SCOPED_FAIL_TRAIL(nondet_var, root_node) save_copy(root_node)
#else
#define SCOPED_LOAD_CUTOFF(slot) ((void)0)
#define SCOPED_MARK_CUTOFF() ((void)0)
#define SCOPED_RETRY(scrutinee_var) ((void)0)
#define SCOPED_RESAVE(root_node) ((void)0)
#define SCOPED_FAIL_TRAIL(nondet_var, root_node) trail_node(root_node, nondet_var)
#endif

// The trail can be used pretty much anywhere, so it almost has
// to be a global variable.  The only alternative is to pass it to every
// single function.
// It's defined in each program's generated main.c.
extern Trail* trail;

// Used to print out the total number of memory allocations
// (see alloc() in memory.h).
extern unsigned long mem;

/* Epoch trailing: a counter that goes up once for every choice point
 * (choose() and push_choice()).
 * A node remembers the epoch it was created in (node.h).
 * If a node is newer than the last choice point,
 * backtracking past that choice point makes the node unreachable,
 * so we don't need to trail its rewrites.
 * This exists even when epoch trailing is off; then it just stays 0.
 */
extern unsigned int current_epoch;

static inline void fail(union field root);
union field copy(union field node);
void save_copy(union field n);
void save_snapshot(union field n);

/* Does rewriting `root` in place need a trail entry first?
 * Two optional filters can each say no:
 *   * (OPT_NONDET_TRAIL): the rewrite didn't read anything nondeterministic,
 *     so it comes out the same whichever alternative an enclosing choice takes.
 *   * (OPT_EPOCH_TRAIL): root was created after the last choice point,
 *     so backtracking past that choice point makes it unreachable anyway.
 *     (This is the WAM's trail condition, using time stamps.)
 * Each is sound alone, and together with the write barrier (see the #error above).
 * `nondet` must already include root's own flag (trail_node does that).
 */
__attribute__((always_inline))
static inline bool needs_trail(union field root, bool nondet)
{
#if OPT_NONDET_TRAIL
    if(!nondet)
    {
        STAT(skipped_nondet);
        return false;
    }
#else
    (void)nondet;
#endif
#if OPT_EPOCH_TRAIL
    if(root.n->epoch >= current_epoch)
    {
        STAT(skipped_epoch);
        return false;
    }
#else
    (void)root; // avoid unused pointer compiler warning
#endif
    STAT(trailed_rewrites);
    return true;
}

/* Trail `root` before an in-place rewrite, if needs_trail says to.
 * `nondet` says whether the rewrite read anything nondeterministic.
 * Root's own flag counts too: flags are sticky, so once a node has been
 * rewritten nondeterministically, every later rewrite of it counts as
 * nondeterministic (backtracking_proofs.md, nondet tracking rule 2).
 * We set root's flag whether or not we pushed an entry,
 * because readers, early backtracking, copy collapse and the barrier read it.
 * The snapshot is taken before the flag changes, so undo() restores both.
 * This is only for rewriting a node with its own result.
 * Choice points and free variable bindings always trail
 * (save_copy, push_choice, choose).
 */
__attribute__((always_inline))
static inline void trail_node(union field root, bool nondet)
{
    nondet |= root.n->nondet;
    STAT(trail_decisions);
    bool trailed = needs_trail(root, nondet);
    if(trailed)
    {
        save_snapshot(root);
    }
#if OPT_STATS
    if(root.n->gc_bits & STAT_LOWERED)
    {
        if(!(root.n->gc_bits & STAT_REWRITTEN))
        {
            STAT(lowered_rewritten);
            root.n->gc_bits |= STAT_REWRITTEN;
        }
        STAT(lowered_rewrites);
        if(trailed)
        {
            STAT(lowered_trailed);
        }
    }
#endif
    root.n->nondet = nondet;
}

/* apply_hnf's version of trail_node.
 * The snapshot keeps root's own epoch.
 * copy() stamps the new node with the current epoch,
 * and undo() restores the whole node with memcpy,
 * so without this an old node would come back looking young,
 * and its next rewrite would wrongly skip the trail.
 * Returns the flag root ends up with, which apply_hnf puts back
 * after set_copy overwrites root with f's contents.
 */
__attribute__((always_inline))
static inline bool push_node(union field root, bool nondet)
{
    nondet |= root.n->nondet;
    STAT(trail_decisions);
    if(needs_trail(root, nondet))
    {
        union field saved = copy(root);
#if OPT_EPOCH_TRAIL
        saved.n->epoch = root.n->epoch;
#endif
        trail_push(trail, root, saved, false);
    }
    root.n->nondet = nondet;
    return nondet;
}

/* The write barrier (backtracking_proofs.md, "The write barrier").
 * Under #1, a deterministic rewrite of an old node isn't trailed.
 * If the new value points at nodes built for it,
 * a later nondeterministic rewrite of one of those would be skipped by #5 (young),
 * and backtracking would leave the old node reaching the stale value.
 *
 * So a node built for a deterministic rewrite's new value takes root's stamp,
 * not the current epoch.  It looks as old as the node it hangs from,
 * and #5 trails its rewrites exactly when it would trail root's.
 * Nothing extra is trailed.
 * A nondeterministic rewrite (root's flag set) stamps with the current epoch as usual.
 * The MIN matters: a node built in a dead branch can carry a stamp above
 * the current epoch, and a new node must never be stamped later than now.
 *
 * Call it after the rewrite's trail_node, which sets root's flag.
 * Generated code does that with REWRITE_STAMP() and wraps each node it
 * builds in STAMPED(...).  Raising a stamp is never safe; lowering one only adds trail entries.
 *
 * The runtime's own C rewrites build only constructors (strings, boxes, lists),
 * apart from apply_hnf's over-applied call (runtime.c).
 * A constructor is never rewritten, so its stamp is never read.
 */
#if OPT_WRITE_BARRIER
__attribute__((always_inline))
static inline unsigned int rewrite_stamp(union field root)
{
    if(root.n->nondet || root.n->epoch >= current_epoch)
    {
        return current_epoch;
    }
    STAT(barrier_lowered);
    return root.n->epoch;
}

__attribute__((always_inline))
static inline union field stamp_node(union field n, unsigned int stamp)
{
    n.n->epoch = stamp;
#if OPT_STATS
    if(stamp < current_epoch)
    {
        n.n->gc_bits |= STAT_LOWERED;
        STAT(lowered_nodes);
    }
#endif
    return n;
}

#define REWRITE_STAMP() unsigned int _stamp = rewrite_stamp(root)
#define STAMPED(e) stamp_node((e), _stamp)
#else
#define REWRITE_STAMP() ((void)0)
#define STAMPED(e) (e)
#endif

/* Follow FORWARD node r one hop, for a case that's reading it.
 *
 * With path compression, we keep going past every forward behind r whose
 * nondet flag is clear, and retarget r straight to where they lead.
 * Later readers of r then skip those hops.
 *  * We only skip unflagged forwards.  Under #1 an unflagged node is never trailed,
 *    so undo never changes a hop we skipped, and r still leads to the right place.
 *    The flags we skip would add nothing to the reader's nondet either.
 *  * Retargeting r is a deterministic write (nondet false) through the ordinary trail decision.
 *    With no trailing optimization it's trailed, under #1 it isn't (unless r's own flag is set),
 *    and under #5 alone it is when r is older than the current epoch.
 *    The entry saves r's one-hop target, so undo puts r back before any hop it skipped.
 *  * r keeps its own flag and epoch.
 * (backtracking_proofs.md, "Path compression").
 */
static inline field follow_forward(field r)
{
    STAT(forward_hops);
    field a = child_at(r, 0);
#if OPT_PATH_COMPRESS
    field b = a;
    while(TAG(b) == FORWARD_TAG && !b.n->nondet)
    {
        STAT(compress_hops_skipped);
        b = child_at(b, 0);
    }
    if(b.n != a.n)
    {
        STAT(compressions);
        trail_node(r, false);
        child_at(r, 0) = b;
    }
    return b;
#else
    return a;
#endif
}

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

RICE_CC void CTR_hnf(union field root, Frame* sp);
RICE_CC void choice_hnf(union field root, Frame* sp);
RICE_CC void apply_hnf(union field root, Frame* sp);
RICE_CC void forward_hnf(union field root, Frame* sp);
RICE_CC void redispatch(union field root, Frame* sp);

// A generated tail call to `code`, which reduces root: f_hnf after set_f,
// choice_hnf after set_choice, apply_hnf after set_apply.
#if OPT_TAIL_DISPATCH
#define TAIL_CALL(code) STAT(tail_calls); MUSTTAIL return code(root, sp)
#else
#define TAIL_CALL(code) STAT(tail_calls); MUSTTAIL return redispatch(root, sp)
#endif

// Narrowing: turn free variable n into the constructor of `like`,
// with a fresh free variable for each pointer child.
void set_free_constructor(union field n, union field like);
void narrow_raw_error(Symbol* sym);

union field copy(union field node);
union field set_copy(union field new_node, union field node);

void save_copy(union field n);
void save(union field n, union field saved);

void push_choice(union field left, union field right);
void push_frame(union field left, union field right);
void choose(union field root);

bool undo(int cutoff);

void print_trail(Trail* s);
void print_trail_entry(TrailEntry* f);
void print_expr(union field n);
void print_final(union field n);
void print_tuple(union field n, int i);
void print_list(union field n);

void nf(union field expr);
void ground_nf(union field expr);
void run_io(union field expr);
void nf_all(union field expr);

void error(char* msg, union field expr);

// functions for manipulating curry strings
union field toCurryString(char* str);
void setCurryString(union field root, char* str);
char* toCStr(union field string);

// Escape one character the way Curry's derived Show does (runtime.c).
// Shared by ext/Prelude.c's show*Literal and runtime.c's printing of solutions.
char* appendEscaped(char* buf, char c, char quote);


static Symbol fail_symbol    = { .tag = FAIL_TAG,     .arity = 0, .name = "FAIL",    .hnf = &CTR_hnf };
static Symbol choice_symbol  = { .tag = CHOICE_TAG,   .arity = 2, .name = "?",       .hnf = &choice_hnf };
static Symbol forward_symbol = { .tag = FORWARD_TAG,  .arity = 1, .name = "->",      .hnf = &forward_hnf };
static Symbol free_symbol    = { .tag = FREE_TAG,     .arity = 0, .name = "free",    .hnf = &CTR_hnf };
static Symbol apply_symbol   = { .tag = FUNCTION_TAG, .arity = 0, .name = "apply",   .hnf = &apply_hnf };

// Placeholder for case shortcutting (developer's manual, "Planned work").
// That isn't implemented yet, and nothing calls make_restore,
// so the fields here don't have to be right yet.
static Symbol backup_symbol  = { .tag = FAIL_TAG,     .arity = 0, .name = "RET",     .hnf = &CTR_hnf };


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

// A choice node ?(left, right, side).
// side is a raw 0/1 that says which alternative to take next (see choose()).
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

/* Copy collapsing.
 * A collapsing rule (`id x = x`, or a case branch that returns one of its variables)
 * normally turns root into a FORWARD to the existing node.
 * We need the forward so that if the target changes later
 * (backtracking, binding a free variable), root sees the change too.
 *
 * If the target can't change anymore, we can make root a copy of it instead,
 * and save every future reader a hop.  That's true when the target is
 *  * already in head normal form (not FUNCTION),
 *  * not a CHOICE (backtracking can still flip it to the other alternative),
 *  * not FREE (binding a free variable rewrites that node in place,
 *    and a copy wouldn't see the binding; a free variable nothing has touched
 *    yet isn't nondet, so the nondet check doesn't catch this),
 *  * and not nondet (something it depends on might still be undone).
 */
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
    if(collapse_safe(target))
    {
        STAT(copy_collapses);
        // root's nondet flag is about root's own history
        // (for example, the branch may have just trailed root, which sets it),
        // not about target's value, so we keep it across the copy.
        // This is the same reason set_copy keeps root's epoch.
        bool keep_nondet = root.n->nondet;
        set_copy(root, target);
        root.n->nondet = keep_nondet;
    }
    else
    {
        STAT(forward_collapses);
        set_forward(root, target);
    }
}
#else
__attribute__((always_inline))
static inline void collapse(union field root, union field target)
{
    STAT(forward_collapses);
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
static inline union field free_var(void)
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
// An apply node stores its own arguments in reverse order:
// apply(f, v1, v2) has f in child 0, v2 in child 1, and v1 in child 2.
// That way the newest argument always sits at a fixed index,
// without knowing f's arity.
// The function's own node is stored forward (child 0 is the first argument),
// so apply_hnf flips them around when it copies the arguments in.
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
    root.n->children[3].a = alloc_spill(1);
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
    n.n->children[3].a = alloc_spill(1);
    child_at(n,0) = f;
    child_at(n,1) = v3;
    child_at(n,2) = v2;
    child_at(n,3) = v1;
    return n;
}

#endif //RUNTIME_H
