// Rice's runtime support for the `external` functions in the Prelude.
// Names use the usual mangling, with 2 underscores between module and function name.
//
// This covers:
//
//   $!  $!!  $##  bindIO  returnIO  getChar  (&)  failed  error
//   show{Int,Float,Char,String}Literal
//   apply  cond  ioError  constrEq ((=:=)'s primitive)
//   nonstrictEq ((=:<=)'s primitive)
//   ensureNotFree  read{Char,String,Nat,Float}Literal
//   readFile  writeFile  appendFile
//
// catch is still an error(...) stub, because we don't have exception handling yet.
//
// Most of these are written as machine code (see machine.h).
// The rest are ordinary C functions (the _impl functions),
// and the _hnf entry points at the bottom of the file call them.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include "runtime.h"
#include "Prelude.h"

// ----------------------------------------------------------------------
// String conversion (needed by any module using a string constant --
// Rice.Codegen.C.ToC's `isStrConst` path calls this by name directly).
// ----------------------------------------------------------------------

field toCurryString(char* str)
{
    char* end = str;
    while(*end != '\0')
    {
        end++;
    }

    field string = make_Prelude___LB_RB(0);
    while(end != str)
    {
        end--;
        field c = make_Prelude__Char((field)(unsigned long)(*end), 0);
        string = make_Prelude___CO(c, string, 0);
    }
    return string;
}

// set_copy, not a raw memcpy: `root` keeps its own epoch (#5) instead of
// taking the fresh string node's. Callers decide about trailing (generated
// code trails before any write to root; see ToC.curry's uncaseTrail).
void setCurryString(field root, char* str)
{
    set_copy(root, toCurryString(str));
}

// A primitive rewriting `root` in place with a value it already built.
// These primitives don't track nondet, so we pass false:
// with OPT_NONDET_TRAIL on this trails nothing,
// and with it off, it's the ordinary trail that #5 relies on.
// set_copy keeps root's own epoch.
static void overwrite_root(field root, field value)
{
    trail_node(root, false);
    set_copy(root, value);
}

/* Settle string node `s` (a cons cell or []).
 * If it's a cons cell, settle its head too, and put the character in *c.
 * settle() only gets us to head normal form (cons vs. nil),
 * so the head needs its own settle before we can read the character.
 * The head is a boxed Char node, so the character itself is the box's child 0.
 * *c is left alone if the list is empty.
 */
static field settleStringNode(field s, char* c)
{
    field node = settle(s, NULL, eval_hnf);
    if(node.n->symbol->tag != Prelude___LB_RB_TAG)
    {
        GC_ROOT(node);  // settle runs the machine
        field head = settle(child_at(node, 0), NULL, eval_hnf);
        GC_UNROOT(1);
        *c = (char)child_at_c(head, 0);
    }
    return node;
}

/* Convert a Curry String to a malloc'd C string.  The caller frees it.
 * The string might not be evaluated yet (read*Literal gets strings built lazily by lex),
 * so we settle every spine node and every character as we go.
 * For a string that's already evaluated, settling doesn't do anything.
 * We walk the string twice: once to get the length, and once to copy the characters.
 */
char* toCStr(field string)
{
    char c;
    // Each step runs the machine; string is read again for the second pass.
    field node = string;
    GC_ROOT(string);
    GC_ROOT(node);
    node = settleStringNode(string, &c);
    int len = 0;
    while(node.n->symbol->tag != Prelude___LB_RB_TAG)
    {
        node = settleStringNode(child_at(node, 1), &c);
        len++;
    }

    char* cstr = (char*)malloc(len + 1);
    cstr[len] = '\0';

    node = settleStringNode(string, &c);
    for(int i = 0; i < len; i++)
    {
        cstr[i] = c;
        node = settleStringNode(child_at(node, 1), &c);
    }
    GC_UNROOT(2);
    return cstr;
}

// ----------------------------------------------------------------------
// Strict application: `f $! x`, `f $!! x`, `f $## x` -- evaluate the
// argument (to head normal form / normal form / ground normal form
// respectively) before applying f to it. All three share the same shape;
// only which forcing function runs differs.
// ----------------------------------------------------------------------

// For $!! and $##: forces x with a nested call (nf/ground_nf aren't on
// the machine yet), then returns whether root is now `apply f x`, ready
// to be reduced with a tail jump; false means root failed.
static bool strictApply(field root, void (*force)(field))
{
    field f = child_at(root, 0);
    field x = child_at(root, 1);
    bool nondet = false;
    GC_ROOT(root);  // force runs the machine
    GC_ROOT(f);
    x = settle(x, &nondet, force);
    GC_UNROOT(2);
    trail_node(root, nondet);
    if(x.n->symbol->tag == FAIL_TAG)
    {
        fail(root);
        return false;
    }
    set_apply1(root, f, x);
    return true;
}

// `f $! x`, on the machine: settle x (head normal form) with frame
// [root, x, nondet], then reduce `apply f x` with a tail jump. The
// evaluation of x lives on the machine stack, so a tail-recursive loop
// written with $! (an accumulator) runs in constant C stack.
static const unsigned char eval1_reps[] = { R_PTR, R_PTR, R_INT };
static RICE_CC void strict_k(union field _root, Frame* sp);
static const FrameInfo strict_info =
    { .code = strict_k, .size = 3, .reps = eval1_reps, .name = "$!" };

RICE_CC void Prelude___DL_EX_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    sp = frame_push(sp, &strict_info);
    SLOT(0) = root;
    SLOT(1) = child_at(root, 1);
    SLOT(2).i = false;
    MUSTTAIL return strict_k(NO_ROOT, sp);
}

static RICE_CC void strict_k(union field _root, Frame* sp)
{
    (void)_root;
    field root = SLOT(0);
    field x = SLOT(1);
    bool nondet = SLOT(2).i;
    EVAL_OR_CONTINUE(x, 1, nondet, 2);
    sp = frame_pop(sp);
    trail_node(root, nondet);
    if(x.n->symbol->tag == FAIL_TAG)
    {
        fail(root);
        RETURN();
    }
    set_apply1(root, child_at(root, 0), x);
    MUSTTAIL return apply_hnf(root, sp);
}

// $!! and $## are C code that runs the machine,
// so we hand sp to C in rice_sp, and read it back afterwards (machine.h).
RICE_CC void Prelude___DL_EX_EX_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_sp = sp;
    GC_ROOT(root);
    bool applied = strictApply(root, nf);
    GC_UNROOT(1);
    sp = rice_sp;
    if(!applied)
    {
        RETURN();
    }
    MUSTTAIL return apply_hnf(root, sp);
}

RICE_CC void Prelude___DL_HT_HT_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_sp = sp;
    GC_ROOT(root);
    bool applied = strictApply(root, ground_nf);
    GC_UNROOT(1);
    sp = rice_sp;
    if(!applied)
    {
        RETURN();
    }
    MUSTTAIL return apply_hnf(root, sp);
}

// ----------------------------------------------------------------------
// IO plumbing.
// We don't have a separate representation for IO actions.
// `bindIO m f` is just "evaluate m, then apply f to it",
// which is the same shape as `$!` above.
// `returnIO x` is just `x`.
// ----------------------------------------------------------------------

/* bindIO m f: m is child 0, and f is child 1.
 *
 * Two surprising things here.
 *
 * First, we fully settle m, chasing forwards, not just one HNF call.
 * A do block evaluates one step at a time, so m often lands on a FORWARD
 * to the next action that hasn't run yet.
 * f is usually `\_ -> next`, which ignores its argument,
 * so if we handed it that forward, the pending actions would never run.
 *
 * Second, IO never backtracks, so bindIO commits to every choice made while it runs.
 * Evaluating m can hit a choice (m might be `x ? y`), and choose() pushes a trail entry.
 * Then we overwrite root with f's result, so nothing can reach that choice anymore.
 * If we left the entry on the trail, nf_all's undo(0) would find it later,
 * restore it, and run the same program again (an extra "SOLUTION: ()").
 * So we record the trail's height before we start, and once root is in head normal form
 * we drop everything above it with trail_pop_to (which doesn't restore anything).
 *
 * On the machine: bind_k settles m with frame [root, m, nondet, cutoff].
 * Then that frame is replaced by a commit frame [cutoff] while `apply f m` runs,
 * and commit_k drops the trail back to the cutoff once root is in head normal form.
 */
static const unsigned char bind_reps[] = { R_PTR, R_PTR, R_INT, R_INT };
static const unsigned char commit_reps[] = { R_INT };
static RICE_CC void bind_k(union field _root, Frame* sp);
static RICE_CC void commit_k(union field _root, Frame* sp);
static const FrameInfo bind_info =
    { .code = bind_k, .size = 4, .reps = bind_reps, .name = "bindIO" };
static const FrameInfo commit_info =
    { .code = commit_k, .size = 1, .reps = commit_reps, .name = "bindIO commit" };

RICE_CC void Prelude__bindIO_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    sp = frame_push(sp, &bind_info);
    SLOT(0) = root;
    SLOT(1) = child_at(root, 0);
    SLOT(2).i = false;
    SLOT(3).i = trail_size(trail);
    MUSTTAIL return bind_k(NO_ROOT, sp);
}

static RICE_CC void bind_k(union field _root, Frame* sp)
{
    (void)_root;
    field root = SLOT(0);
    field m = SLOT(1);
    bool nondet = SLOT(2).i;
    EVAL_OR_CONTINUE(m, 1, nondet, 2);
    long cutoff = SLOT(3).i;
    sp = frame_pop(sp);
    sp = frame_push(sp, &commit_info);
    SLOT(0).i = cutoff;
    set_apply1(root, child_at(root, 1), m);
    MUSTTAIL return apply_hnf(root, sp);
}

static RICE_CC void commit_k(union field _root, Frame* sp)
{
    (void)_root;
    long cutoff = SLOT(0).i;
    sp = frame_pop(sp);
    trail_pop_to(trail, (int)cutoff);
    RETURN();
}

static void Prelude__returnIO_impl(void)
{
    field root = rice_root;
    set_forward(root, child_at(root, 0));
}

static void Prelude__getChar_impl(void)
{
    field root = rice_root;
    int c = getchar();
    set_Prelude__Char(root, (field)(unsigned long)c, 0);
}

/* prim_putChar :: Char# -> IO ()
 * The argument is the raw char (replace_Prim.curry's putChar already unboxed it).
 * Unlike the pure primitives in Rice.Codegen.C.PrimOps, which are inlined as C expressions,
 * this has to be a real function that only runs when something forces it.
 * putchar's side effect has to happen in the order bindIO runs things,
 * not whenever the thunk happens to get built.
 */
static void Prelude__prim_USputChar_impl(void)
{
    field root = rice_root;
    putchar((int)child_at_c(root, 0));
    set_Prelude___LP_RP(root, 0);
}

// ----------------------------------------------------------------------
// error :: String -> a -- the one primitive whose whole job already *is*
// reporting a fatal error, so it goes through runtime.h's own error()
// helper directly rather than a raw exit().
// ----------------------------------------------------------------------

static void Prelude__prim_USerror_impl(void)
{
    field root = rice_root;
    GC_ROOT(root);  // toCStr runs the machine
    char* msg = toCStr(child_at(root, 0));
    GC_UNROOT(1);
    error(msg, root);
}

// ----------------------------------------------------------------------
// show*Literal: straightforward sprintf + toCurryString.
// ----------------------------------------------------------------------

static void Prelude__prim_USshowIntLiteral_impl(void)
{
    field root = rice_root;
    char buf[32];
    snprintf(buf, sizeof(buf), "%ld", child_at_i(root, 0));
    overwrite_root(root, toCurryString(buf));
}

static void Prelude__prim_USshowFloatLiteral_impl(void)
{
    field root = rice_root;
    char buf[64];
    snprintf(buf, sizeof(buf), "%f", child_at_f(root, 0));
    overwrite_root(root, toCurryString(buf));
}

static void Prelude__prim_USshowCharLiteral_impl(void)
{
    field root = rice_root;
    char c = (char)child_at_c(root, 0);
    char buf[8];
    char* p = buf;
    *p++ = '\'';
    p = appendEscaped(p, c, '\'');
    *p++ = '\'';
    *p = '\0';
    overwrite_root(root, toCurryString(buf));
}

static void Prelude__prim_USshowStringLiteral_impl(void)
{
    field root = rice_root;
    GC_ROOT(root);  // toCStr runs the machine
    char* s = toCStr(child_at(root, 0));
    GC_UNROOT(1);
    size_t len = strlen(s);
    // Worst case every byte expands to a 4-byte decimal escape, plus the
    // two surrounding quotes and the terminator.
    char* buf = (char*)malloc(4 * len + 3);
    char* p = buf;
    *p++ = '"';
    for(size_t i = 0; i < len; i++)
    {
        p = appendEscaped(p, s[i], '"');
    }
    *p++ = '"';
    *p = '\0';
    overwrite_root(root, toCurryString(buf));
    free(s);
    free(buf);
}

// ----------------------------------------------------------------------
// (&): "committed"/concurrent conjunction
// (`x & y`, both must reduce to True).
// Some Curry implementations can evaluate both sides concurrently;
// Rice has no concurrency yet, so this is sequential,
// This works like (&&)'s definition (`True && x = x`)
//
// failed: fails unconditionally.
// ----------------------------------------------------------------------

/* `x & y`: settle x (frame [root, x, nondet]).
 * root fails if x failed, is False if x is False, and otherwise becomes y.
 * We have to settle x, not just evaluate it once:
 * x often ends up as a FORWARD (a dictionary method whose result is another call),
 * and a FORWARD isn't FAIL or False, so we'd wrongly treat it as True.
 */
static RICE_CC void and_k(union field _root, Frame* sp);
static const FrameInfo and_info =
    { .code = and_k, .size = 3, .reps = eval1_reps, .name = "&" };

RICE_CC void Prelude___AN_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    sp = frame_push(sp, &and_info);
    SLOT(0) = root;
    SLOT(1) = child_at(root, 0);
    SLOT(2).i = false;
    MUSTTAIL return and_k(NO_ROOT, sp);
}

static RICE_CC void and_k(union field _root, Frame* sp)
{
    (void)_root;
    field root = SLOT(0);
    field x = SLOT(1);
    bool nondet = SLOT(2).i;
    EVAL_OR_CONTINUE(x, 1, nondet, 2);
    sp = frame_pop(sp);
    trail_node(root, nondet);
    if(x.n->symbol->tag == FAIL_TAG)
    {
        fail(root);
    }
    else if(x.n->symbol->tag == Prelude__False_TAG)
    {
        set_Prelude__False(root, 0);
    }
    else
    {
        set_forward(root, child_at(root, 1));
    }
    RETURN();
}

static void Prelude__failed_impl(void)
{
    field root = rice_root;
    trail_node(root, false);
    fail(root);
}

// ----------------------------------------------------------------------
// apply :: (a -> b) -> a -> b -- the general, "called as an ordinary
// function" fallback.
// Rice.Codegen.C.ToC has a special-case for every direct call to Prelude.apply
// into set_apply1+apply_hnf right at the call site
// (isApply, ToC.curry), which skips this entirely.
// But we can still create apply nodes (like `map apply`), so we need to handle it.
//
// cond :: Bool -> a -> a: FlatCurry's representation of a guarded rule
// (`f x | c = e` compiles to `f x = cond c e`): succeeds with e if c
// reduces to True, fails otherwise. Same nondet/FAIL bookkeeping shape as
// (&) above, just returning y instead of a boolean.
// ----------------------------------------------------------------------

// Prelude.apply f x: rewrite root to the runtime's own apply node and
// reduce it with a tail jump.
RICE_CC void Prelude__apply_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    set_apply1(root, child_at(root, 0), child_at(root, 1));
    MUSTTAIL return apply_hnf(root, sp);
}

// `cond c x` (a guarded rule): settle c (frame [root, c, nondet]);
// root becomes x if c is True, and fails otherwise.
static RICE_CC void cond_k(union field _root, Frame* sp);
static const FrameInfo cond_info =
    { .code = cond_k, .size = 3, .reps = eval1_reps, .name = "cond" };

RICE_CC void Prelude__cond_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    sp = frame_push(sp, &cond_info);
    SLOT(0) = root;
    SLOT(1) = child_at(root, 0);
    SLOT(2).i = false;
    MUSTTAIL return cond_k(NO_ROOT, sp);
}

static RICE_CC void cond_k(union field _root, Frame* sp)
{
    (void)_root;
    field root = SLOT(0);
    field c = SLOT(1);
    bool nondet = SLOT(2).i;
    EVAL_OR_CONTINUE(c, 1, nondet, 2);
    sp = frame_pop(sp);
    trail_node(root, nondet);
    if(c.n->symbol->tag == Prelude__True_TAG)
    {
        set_forward(root, child_at(root, 1));
    }
    else
    {
        fail(root);
    }
    RETURN();
}

// ----------------------------------------------------------------------
// ioError :: IOError -> IO _ (`ioError err = prim_ioError $## err`):
// raises a fatal error carrying the IOError's message. Every IOError
// constructor (IOError/UserError/FailError/NondetError) wraps exactly one
// String, so the message is always child 0. We just report the raw message,
// without Show's "user error: " style prefix,
// since there's no `catch` yet to make the difference matter.
// ----------------------------------------------------------------------

static void Prelude__prim_USioError_impl(void)
{
    field root = rice_root;
    field err = child_at(root, 0);
    // We need err to be an actual IOError constructor before we read its message.
    // ioError's definition already forces err with $##, so this settle is just defensive.
    // We don't need nondet: error() exits, so nothing ever backtracks into this.
    GC_ROOT(root);  // settle and toCStr run the machine
    GC_ROOT(err);
    err = settle(err, NULL, eval_hnf);
    char* msg = toCStr(child_at(err, 0));
    GC_UNROOT(2);
    error(msg, root);
}

// ----------------------------------------------------------------------
// constrEq/nonstrictEq: the primitives (=:=) and (=:<=) actually
// delegate to. Neither ever *returns* False: a term that can't unify
// makes the whole computation fail (fail(root)), same as every other
// primitive here that models a Curry constraint rather than a boolean
// function.
//
// unify_step (=:=/constrEq, strict): the caller nf()'s both sides fully
// first, so the only free variables either side can still contain are
// genuine, never-bound logic variables, which are bound directly to whatever's on
// the other side, no narrowing needed. nf() doesn't remove FORWARD nodes,
// so this still has to chase forwards itself at every level, same as every other consumer.
//
// *nondet accumulates whether the outcome depends on anything a choice
// point could still revert, for the caller's trail decision on root (#1):
// the flag of every node visited, forwards included (a resolved choice is
// a forward with nondet set, see choose()), and true whenever a free
// variable gets bound -- like narrowing, the binding is undone on
// backtracking, so a root left saying True without it would be stale.
// Every node the result depends on is visited before returning, so the
// early `return false`s need nothing extra.
// ----------------------------------------------------------------------

// Whether two raw values of the same rep are equal.
static bool raw_equal(field a, field b, FieldRep r)
{
    switch(r)
    {
        case R_INT:
            return a.i == b.i;
        case R_CHAR:
            return a.c == b.c;
        case R_FLOAT:
            return a.f == b.f;
        case R_PTR:
            break;
    }
    return false;
}

// One pending comparison: a pointer pair (rep R_PTR) to unify, or a raw
// pair to compare by value.
typedef struct
{
    field x;
    field y;
    FieldRep rep;
} UnifyPair;

static bool unify_step(field x0, field y0, bool* nondet)
{
    // Depth-first, children left to right.
    // An explicit work list keeps deep data (a long list) off the C stack.
    size_t cap = 64;
    size_t n = 0;
    UnifyPair* work = (UnifyPair*)malloc(cap * sizeof(UnifyPair));
    work[n++] = (UnifyPair){ x0, y0, R_PTR };
    bool ok = true;
    while(ok && n > 0)
    {
        UnifyPair p = work[--n];
        if(p.rep != R_PTR)
        {
            ok = raw_equal(p.x, p.y, p.rep);
            continue;
        }
        field x = p.x;
        field y = p.y;
        *nondet |= x.n->nondet || y.n->nondet;
        while(x.n->symbol->tag == FORWARD_TAG)
        {
            x = child_at(x, 0);
            *nondet |= x.n->nondet;
        }
        while(y.n->symbol->tag == FORWARD_TAG)
        {
            y = child_at(y, 0);
            *nondet |= y.n->nondet;
        }

        // one side failed, we can't unify
        if(x.n->symbol->tag == FAIL_TAG || y.n->symbol->tag == FAIL_TAG)
        {
            ok = false;
            continue;
        }

        // Both sides are the same node, so they already unify.
        // This matters for x =:= x with x free:
        // binding x to itself would make a FORWARD that points at itself,
        // and anything that read x afterwards would loop forever.
        // (This isn't an occurs check; we still don't do one.)
        if(x.n == y.n)
        {
            continue;
        }

        //one side if free, set it to point to the other side
        if(x.n->symbol->tag == FREE_TAG)
        {
            *nondet = true;
            save_copy(x);
            set_forward(x, y);
            continue;
        }
        if(y.n->symbol->tag == FREE_TAG)
        {
            *nondet = true;
            save_copy(y);
            set_forward(y, x);
            continue;
        }

        // the constructors don't match, we fail.
        if(x.n->symbol->tag != y.n->symbol->tag)
        {
            ok = false;
            continue;
        }

        // Children, pushed last first so child 0 is unified first.
        unsigned int arity = x.n->symbol->arity;
        if(n + arity > cap)
        {
            while(n + arity > cap)
            {
                cap *= 2;
            }
            work = (UnifyPair*)realloc(work, cap * sizeof(UnifyPair));
        }
        for(unsigned int i = arity; i-- > 0; )
        {
            work[n++] = (UnifyPair){ child_at_v(x, i), child_at_v(y, i),
                                     child_rep(x.n->symbol, i) };
        }
    }
    free(work);
    return ok;
}

static void Prelude__constrEq_impl(void)
{
    field root = rice_root;
    field x = child_at(root, 0);
    field y = child_at(root, 1);
    GC_ROOT(root);  // nf runs the machine
    GC_ROOT(x);
    GC_ROOT(y);
    nf(x);
    nf(y);
    GC_UNROOT(3);
    // Decided after unifying (unify_step reports what the outcome read),
    // but before root is written. unify_step's own free-variable bindings
    // are trailed separately, so the order of the two entries doesn't matter.
    bool nondet = false;
    bool ok = unify_step(x, y, &nondet);
    trail_node(root, nondet);
    if(ok)
    {
        set_Prelude__True(root, 0);
    }
    else
    {
        fail(root);
    }
}

// lazy_unify_step (=:<=/nonstrictEq, "Declarative Programming with Function Patterns"):
// unlike unify_step, s is only evaluated to HNF.
// A free variable on the s side becomes a FORWARD to t directly
// (t can stay unevaluated);
// a free variable on the t side is narrowed
// to match s's already-known head constructor.
// Returns both success and whether any narrowing
// step touched a genuinely nondeterministic value, same "caller decides
// whether to trail" convention (trail_node) as strictApply/cond/(&) above.
// ----------------------------------------------------------------------

typedef struct
{
    bool ok;
    bool nondet;
} LazyResult;

// On the machine, each pending pair (s, t) has a frame
//   [s, t, scruts, scrutt, phase, child, nondet, cutoff]
// phase 0 settles s, phase 1 settles t (narrowing a free t to s's shape),
// phase 2 unifies the children one at a time: a pointer child pushes its
// own pair frame and jumps, and its result comes back in lu_result. A pair
// that finishes pops its frame, sets lu_result, and returns to its parent.
// Under OPT_SCOPED_BACKTRACK a failing pair retries from the start if
// undo() finds a choice made since the pair began (cutoff).
static LazyResult lu_result;

static const unsigned char lu_reps[] =
    { R_PTR, R_PTR, R_PTR, R_PTR, R_INT, R_INT, R_INT, R_INT };
static RICE_CC void lu_k(union field _root, Frame* sp);
static const FrameInfo lu_info =
    { .code = lu_k, .size = 8, .reps = lu_reps, .name = "=:<= pair" };

static inline Frame* lu_push(Frame* sp, field s, field t)
{
    sp = frame_push(sp, &lu_info);
    SLOT(0) = s;
    SLOT(1) = t;
    SLOT(2) = s;
    SLOT(3) = t;
    SLOT(4).i = 0;
    SLOT(5).i = 0;
    SLOT(6).i = false;
    SLOT(7).i = trail_size(trail);
    return sp;
}

static RICE_CC void lu_k(union field _root, Frame* sp)
{
    (void)_root;
    field scruts = SLOT(2);
    field scrutt = SLOT(3);
    long phase = SLOT(4).i;
    bool nondet = SLOT(6).i;
    int n = (int)SLOT(7).i;
    (void)n; // only read under OPT_SCOPED_BACKTRACK
    bool ok = true;

    if(phase == 0)
    {
        while(true)
        {
            nondet |= scruts.n->nondet;
            unsigned char tg = scruts.n->symbol->tag;
            if(tg == FAIL_TAG)
            {
                ok = false;
                goto finish;
            }
            else if(tg == FREE_TAG)
            {
                // If t is this same variable (x =:<= x), there's nothing to bind.
                // Binding x to itself would make a FORWARD that points at itself.
                // t isn't evaluated yet, so we only look through its forwards.
                field t = SLOT(1);
                field target = t;
                while(target.n->symbol->tag == FORWARD_TAG)
                {
                    nondet |= target.n->nondet;
                    target = child_at(target, 0);
                }
                sp = frame_pop(sp);
                if(target.n == scruts.n)
                {
                    lu_result = (LazyResult){ true, nondet };
                    RETURN();
                }
                save_copy(scruts);
                set_forward(scruts, t);
                lu_result = (LazyResult){ true, true };
                RETURN();
            }
            else if(tg == FORWARD_TAG)
            {
                scruts = child_at(scruts, 0);
            }
            else if(tg == FUNCTION_TAG)
            {
                SLOT(2) = scruts;
                SLOT(6).i = nondet;
                MUSTTAIL return scruts.n->symbol->hnf(scruts, sp);

            }
            else
            {
                break;
            }
        }
        SLOT(2) = scruts;
        phase = 1;
        SLOT(4).i = 1;
    }

    if(phase == 1)
    {
        while(true)
        {
            nondet |= scrutt.n->nondet;
            unsigned char tg = scrutt.n->symbol->tag;
            if(tg == FAIL_TAG)
            {
                ok = false;
                goto finish;
            }
            else if(tg == FREE_TAG)
            {
                save_copy(scrutt);
                set_free_constructor(scrutt, scruts);
                nondet = true;
            }
            else if(tg == FORWARD_TAG)
            {
                scrutt = child_at(scrutt, 0);
            }
            else if(tg == FUNCTION_TAG)
            {
                SLOT(3) = scrutt;
                SLOT(6).i = nondet;
                MUSTTAIL return scrutt.n->symbol->hnf(scrutt, sp);

            }
            else
            {
                break;
            }
        }
        SLOT(3) = scrutt;
        if(scruts.n->symbol->tag != scrutt.n->symbol->tag)
        {
            ok = false;
            goto finish;
        }
        phase = 2;
        SLOT(4).i = 2;
        SLOT(5).i = 0;
    }
    else
    {
        // phase 2, resumed: child SLOT(5) has just been unified.
        nondet |= lu_result.nondet;
        if(!lu_result.ok)
        {
            ok = false;
            goto finish;
        }
        SLOT(5).i++;
    }

    // phase 2: the remaining children, in order.
    for(long i = SLOT(5).i; i < (long)scruts.n->symbol->arity; i++)
    {
        FieldRep rep = child_rep(scruts.n->symbol, (int)i);
        if(rep != R_PTR)
        {
            if(!raw_equal(child_at_v(scruts, i), child_at_v(scrutt, i), rep))
            {
                ok = false;
                goto finish;
            }
            continue;
        }
        SLOT(5).i = i;
        SLOT(6).i = nondet;
        sp = lu_push(sp, child_at_v(scruts, i), child_at_v(scrutt, i));
        MUSTTAIL return lu_k(NO_ROOT, sp);
    }

finish:
    #if OPT_SCOPED_BACKTRACK
    if(!ok && undo(n))
    {
        // Retry the pair from scratch.
        SLOT(2) = SLOT(0);
        SLOT(3) = SLOT(1);
        SLOT(4).i = 0;
        SLOT(5).i = 0;
        SLOT(6).i = false;
        SLOT(7).i = trail_size(trail);
        MUSTTAIL return lu_k(NO_ROOT, sp);
    }
    #endif
    sp = frame_pop(sp);
    lu_result = (LazyResult){ ok, nondet };
    RETURN();
}

// x =:<= y: unify the pair on the machine (lu_k), then nseq_k sets root
// from the result.
static const unsigned char nseq_reps[] = { R_PTR };
static RICE_CC void nseq_k(union field _root, Frame* sp);
static const FrameInfo nseq_info =
    { .code = nseq_k, .size = 1, .reps = nseq_reps, .name = "=:<=" };

RICE_CC void Prelude__nonstrictEq_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    sp = frame_push(sp, &nseq_info);
    SLOT(0) = root;
    sp = lu_push(sp, child_at(root, 0), child_at(root, 1));
    MUSTTAIL return lu_k(NO_ROOT, sp);
}

static RICE_CC void nseq_k(union field _root, Frame* sp)
{
    (void)_root;
    field root = SLOT(0);
    sp = frame_pop(sp);
    trail_node(root, lu_result.nondet);
    if(lu_result.ok)
    {
        set_Prelude__True(root, 0);
    }
    else
    {
        fail(root);
    }
    RETURN();
}

// ----------------------------------------------------------------------
// ensureNotFree :: a -> a
//
// This only does part of the job.
// In KiCS2, ensureNotFree narrows an unbound free variable to one of its type's constructors.
// We can't do that here: we're called the same way for every type,
// so we don't know which constructors to try.
// (A generated FREE case can narrow, because the code generator knows the type there.)
//
// So we settle x like everything else does, and pass a free variable through unchanged.
// That's right when the caller just needed some value forced,
// and wrong when it really needed the result to not be free.
// In practice we only get here if a Curry program calls $#, ensureNotFree,
// or ensureSpine itself; nothing Rice generates does.
// ----------------------------------------------------------------------

// ensureNotFree x: settle x (frame [root, x, nondet]); root forwards to it.
static RICE_CC void notfree_k(union field _root, Frame* sp);
static const FrameInfo notfree_info =
    { .code = notfree_k, .size = 3, .reps = eval1_reps, .name = "ensureNotFree" };

RICE_CC void Prelude__ensureNotFree_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    sp = frame_push(sp, &notfree_info);
    SLOT(0) = root;
    SLOT(1) = child_at(root, 0);
    SLOT(2).i = false;
    MUSTTAIL return notfree_k(NO_ROOT, sp);
}

static RICE_CC void notfree_k(union field _root, Frame* sp)
{
    (void)_root;
    field root = SLOT(0);
    field x = SLOT(1);
    bool nondet = SLOT(2).i;
    EVAL_OR_CONTINUE(x, 1, nondet, 2);
    sp = frame_pop(sp);
    trail_node(root, false);
    set_forward(root, x);
    RETURN();
}

// ----------------------------------------------------------------------
// File I/O. Reads/writes the whole file in one call (no streaming/lazy
// I/O -- readFile's own Curry-level laziness is a bigger, separate
// design question, same category as exceptions below). A failure
// (nonexistent file, permission denied, ...) is fatal -- real Curry
// signals this as a catchable IOError, but real exception handling
// isn't designed yet (see catch's own stub just below), so this can
// only ever be the uncatchable, whole-program-ending kind of failure
// for now.
// ----------------------------------------------------------------------

/* Read the whole file at `path` into a fresh, NUL terminated buffer.
 * The caller frees it.
 * `what` is the name of the Curry function, for the error message.
 * Since we use C strings, an embedded NUL byte in the file
 * would cut the Curry string short.
 */
static char* readWholeFile(const char* path, const char* what)
{
    FILE* f = fopen(path, "r");
    if(f == NULL)
    {
        char msg[512];
        snprintf(msg, sizeof(msg), "%s: %s: %s", what, path, strerror(errno));
        error(msg, make_Prelude___LP_RP(0));
    }
    size_t cap = 4096;
    size_t len = 0;
    char* buf = (char*)malloc(cap);
    size_t n;
    while((n = fread(buf + len, 1, cap - len, f)) > 0)
    {
        len += n;
        if(len == cap)
        {
            cap *= 2;
            buf = (char*)realloc(buf, cap);
        }
    }
    fclose(f);
    buf[len] = '\0';
    return buf;
}

static void Prelude__prim_USreadFile_impl(void)
{
    field root = rice_root;
    GC_ROOT(root);  // toCStr runs the machine
    char* path = toCStr(child_at(root, 0));
    GC_UNROOT(1);
    char* content = readWholeFile(path, "readFile");
    free(path);
    overwrite_root(root, toCurryString(content));
    free(content);
}

// Shared by writeFile ("w", truncate) and appendFile ("a", append).
// mode is the fopen mode letter.
static void writeToFile(field root, char mode)
{
    GC_ROOT(root);  // toCStr runs the machine
    char* path = toCStr(child_at(root, 0));
    char* content = toCStr(child_at(root, 1));
    GC_UNROOT(1);
    char fmode[2] = { mode, '\0' };
    FILE* f = fopen(path, fmode);
    if(f == NULL)
    {
        const char* what;
        if(mode == 'w')
        {
            what = "writeFile";
        }
        else
        {
            what = "appendFile";
        }
        char msg[512];
        snprintf(msg, sizeof(msg), "%s: %s: %s", what, path, strerror(errno));
        free(path);
        free(content);
        error(msg, root);
    }
    fputs(content, f);
    fclose(f);
    free(path);
    free(content);
    set_Prelude___LP_RP(root, 0);
}

static void Prelude__prim_USwriteFile_impl(void)
{
    field root = rice_root;
    writeToFile(root, 'w');
}

static void Prelude__prim_USappendFile_impl(void)
{
    field root = rice_root;
    writeToFile(root, 'a');
}

// ----------------------------------------------------------------------
// Deferred stubs: crash the program rather than silently fail.
// We don't have exception handling yet.
// ----------------------------------------------------------------------

static void Prelude__catch_impl(void)
{
    field root = rice_root;
    error("catch not implemented yet", root);
}

// ----------------------------------------------------------------------
// read*Literal: the inverse of show*Literal above.
// Each is a `ReadS a` (`String -> [(a, String)]`):
// parse a literal at the start of the input, and return it with whatever is left.
// `[]` means it didn't parse.
// The Prelude's callers (readsPrec for Char, Int, and Float) only keep a result
// whose rest is empty, so parsing a prefix is correct for them,
// and for any program that calls these directly.
//
// Escapes are the exact inverse of appendEscaped (runtime.c):
// the same named escapes, and the same decimal \NNN fallback.
// ----------------------------------------------------------------------

static bool isAsciiDigit(char c)
{
    return c >= '0' && c <= '9';
}

// Decodes the escape starting right after the backslash at `p` (not
// included), writes the decoded byte to `*out`, and returns how many
// bytes of `p` it consumed -- 0 means unrecognized/malformed.
static int parseEscape(const char* p, char* out)
{
    switch(*p)
    {
        case '\\':
            *out = '\\';
            return 1;
        case '\'':
            *out = '\'';
            return 1;
        case '"':
            *out = '"';
            return 1;
        case 'a':
            *out = '\a';
            return 1;
        case 'b':
            *out = '\b';
            return 1;
        case 'f':
            *out = '\f';
            return 1;
        case 'n':
            *out = '\n';
            return 1;
        case 'r':
            *out = '\r';
            return 1;
        case 't':
            *out = '\t';
            return 1;
        case 'v':
            *out = '\v';
            return 1;
        default:
            if(isAsciiDigit(*p))
            {
                int val = 0;
                int n = 0;
                while(n < 3 && isAsciiDigit(p[n]))
                {
                    val = val * 10 + (p[n] - '0');
                    n++;
                }
                *out = (char)val;
                return n;
            }
            return 0;
    }
}

typedef struct
{
    bool ok;
    char value;
    const char* rest;
} CharParse;

static CharParse tryParseCharLiteral(const char* s)
{
    if(s[0] != '\'')
    {
        return (CharParse){ false, 0, s };
    }
    const char* p = s + 1;
    char c;
    if(*p == '\\')
    {
        int n = parseEscape(p + 1, &c);
        if(n == 0)
        {
            return (CharParse){ false, 0, s };
        }
        p += 1 + n;
    }
    else if(*p == '\0' || *p == '\'')
    {
        return (CharParse){ false, 0, s }; // empty '' or unterminated
    }
    else
    {
        c = *p;
        p += 1;
    }
    if(*p != '\'')
    {
        return (CharParse){ false, 0, s };
    }
    return (CharParse){ true, c, p + 1 };
}

typedef struct
{
    bool ok;
    char* value;
    const char* rest;
} StringParse;

// On success, `value` is a fresh malloc'd, NUL-terminated C string the
// caller must free.
static StringParse tryParseStringLiteral(const char* s)
{
    if(s[0] != '"')
    {
        return (StringParse){ false, NULL, s };
    }
    const char* p = s + 1;
    size_t cap = 64;
    size_t len = 0;
    char* buf = (char*)malloc(cap);
    while(*p != '"')
    {
        if(*p == '\0')
        {
            free(buf);
            return (StringParse){ false, NULL, s };
        }
        char c;
        if(*p == '\\')
        {
            int n = parseEscape(p + 1, &c);
            if(n == 0)
            {
                free(buf);
                return (StringParse){ false, NULL, s };
            }
            p += 1 + n;
        }
        else
        {
            c = *p;
            p += 1;
        }
        if(len + 1 >= cap)
        {
            cap *= 2;
            buf = (char*)realloc(buf, cap);
        }
        buf[len++] = c;
    }
    buf[len] = '\0';
    return (StringParse){ true, buf, p + 1 };
}

typedef struct
{
    bool ok;
    double value;
    const char* rest;
} FloatParse;

static FloatParse tryParseFloatLiteral(const char* s)
{
    // A Curry Float literal always starts with a digit (readSigned handles the sign).
    // We check that ourselves, because strtod would also accept
    // a leading sign, "nan", or "inf".
    if(!isAsciiDigit(s[0]))
    {
        return (FloatParse){ false, 0, s };
    }
    char* end;
    double v = strtod(s, &end);
    if(end == s)
    {
        return (FloatParse){ false, 0, s };
    }
    return (FloatParse){ true, v, end };
}

// Every read*Literal below either returns `[]` (noParse)
// or a one-element list holding the (value, rest) pair (oneParse).
static field noParse(void)
{
    return make_Prelude___LB_RB(0);
}

static field oneParse(field value, const char* rest)
{
    field pair = make_Prelude___LP_CM_RP(value, toCurryString((char*)rest), 0);
    return make_Prelude___CO(pair, make_Prelude___LB_RB(0), 0);
}

static void Prelude__prim_USreadNatLiteral_impl(void)
{
    field root = rice_root;
    GC_ROOT(root);  // toCStr runs the machine
    char* s = toCStr(child_at(root, 0));
    GC_UNROOT(1);
    field result;
    if(!isAsciiDigit(s[0]))
    {
        result = noParse();
    }
    else
    {
        char* p = s;
        long value = 0;
        while(isAsciiDigit(*p))
        {
            value = value * 10 + (*p - '0');
            p++;
        }
        result = oneParse(make_Prelude__Int((field)(long)value, 0), p);
    }
    overwrite_root(root, result);
    free(s);
}

static void Prelude__prim_USreadCharLiteral_impl(void)
{
    field root = rice_root;
    GC_ROOT(root);  // toCStr runs the machine
    char* s = toCStr(child_at(root, 0));
    GC_UNROOT(1);
    CharParse r = tryParseCharLiteral(s);
    field result;
    if(r.ok)
    {
        field c = make_Prelude__Char((field)(unsigned long)(unsigned char)r.value, 0);
        result = oneParse(c, r.rest);
    }
    else
    {
        result = noParse();
    }
    overwrite_root(root, result);
    free(s);
}

static void Prelude__prim_USreadStringLiteral_impl(void)
{
    field root = rice_root;
    GC_ROOT(root);  // toCStr runs the machine
    char* s = toCStr(child_at(root, 0));
    GC_UNROOT(1);
    StringParse r = tryParseStringLiteral(s);
    field result;
    if(r.ok)
    {
        result = oneParse(toCurryString(r.value), r.rest);
    }
    else
    {
        result = noParse();
    }
    overwrite_root(root, result);
    if(r.ok)
    {
        free(r.value);
    }
    free(s);
}

static void Prelude__prim_USreadFloatLiteral_impl(void)
{
    field root = rice_root;
    GC_ROOT(root);  // toCStr runs the machine
    char* s = toCStr(child_at(root, 0));
    GC_UNROOT(1);
    FloatParse r = tryParseFloatLiteral(s);
    field result;
    if(r.ok)
    {
        result = oneParse(make_Prelude__Float((field)(double)r.value, 0), r.rest);
    }
    else
    {
        result = noParse();
    }
    overwrite_root(root, result);
    free(s);
}

// ----------------------------------------------------------------------
// Machine entry points (runtime/machine.h) for the C functions above.
//
// They all have the same shape:
//  * GC_SAFE_POINT: collect if we need to, before we look at root.
//  * Copy root and sp into rice_root and rice_sp,
//    because the _impl function is ordinary C code and can't see our registers.
//  * Run the _impl function.  It might run the machine (toCStr, nf, settle),
//    and a nested run can move the stack.
//  * So read sp back out of rice_sp before we RETURN().
// ----------------------------------------------------------------------

RICE_CC void Prelude__returnIO_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__returnIO_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__getChar_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__getChar_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USputChar_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USputChar_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USerror_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USerror_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USshowIntLiteral_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USshowIntLiteral_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USshowFloatLiteral_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USshowFloatLiteral_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USshowCharLiteral_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USshowCharLiteral_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USshowStringLiteral_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USshowStringLiteral_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__failed_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__failed_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USioError_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USioError_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__constrEq_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__constrEq_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USreadFile_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USreadFile_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USwriteFile_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USwriteFile_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USappendFile_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USappendFile_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__catch_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__catch_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USreadNatLiteral_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USreadNatLiteral_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USreadCharLiteral_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USreadCharLiteral_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USreadStringLiteral_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USreadStringLiteral_impl();
    sp = rice_sp;
    RETURN();
}

RICE_CC void Prelude__prim_USreadFloatLiteral_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    rice_sp = sp;
    Prelude__prim_USreadFloatLiteral_impl();
    sp = rice_sp;
    RETURN();
}
