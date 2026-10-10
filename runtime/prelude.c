// Rice's runtime support for `external` prelude function.
// This supersedes the old external.c/external.h.
// and use modern conventions, 
// like 2 underscores between module and function name.
//
// now covers completely:
//
//   $!  $!!  $##  bindIO  returnIO  getChar  (&)  failed  error
//   show{Int,Float,Char,String}Literal
//   apply  cond  ioError  constrEq ((=:=)'s primitive)
//   nonstrictEq ((=:<=)'s primitive)
//   catch  ensureNotFree  read{Char,String,Nat,Float}Literal
//   readFile  writeFile  appendFile
//
// The first three groups are real implementations; the last group are
// error(...) stubs for functionality this file doesn't implement yet.
// This includes
//  * real exception handling
//  * the parsing direction of literal show/read, 
//  * file I/O.

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
    while(*end != '\0') { end++; }

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

// A primitive rewriting `root` in place with an already-built value.
// Trails like any other rewrite, at the point of the write (after
// whatever forcing produced `value`). nondet is false: these primitives
// don't track it, so under OPT_NONDET_TRAIL this trails nothing, exactly
// as before; with #1 off it is the baseline trail #5 relies on. set_copy
// keeps root's own epoch.
static void overwrite_root(field root, field value)
{
    trail_node(root, false);
    set_copy(root, value);
}

// (:)'s children are forward-stored, same as any other ordinary
// constructor (child 0 the head, child 1 the tail -- Rice.Codegen.C.ToH's
// setRealChildren; not the reversed convention `apply`'s own missing-
// argument slots use, runtime.h's own note on that) -- this used to read
// them backwards, the same bug (and likely just as untested until now)
// as runtime.c's print_string/print_list/print_tuple.
// Settles `s` and, if it's a cons cell, its own head too (settle()
// alone only reaches WHNF, i.e. cons-vs-nil -- toCStr also needs the
// character payload itself resolved before reading it). Returns the
// settled list node and, via `*c`, its head's char value (undefined if
// the list turned out to be empty -- callers only read it after
// checking for that).
static field settleStringNode(field s, char* c)
{
    field node = settle(s, NULL, eval_hnf);
    if(node.n->symbol->tag != Prelude___LB_RB_TAG)
    {
        // `head` is a *reference to the boxed Char node* (child_at(node,0)
        // returns a Node reference, same as any other constructor's own
        // child), not the raw character value itself -- the actual value
        // is one level further in, at that node's own child 0
        // (child_at_c, same as the rest of this file reads a Char's
        // payload). Originally read as `head.n->children[0].c` (this
        // file's very first version, before settle() was added here);
        // rewriting to add settle() briefly regressed this to `head.c`
        // directly (reading the Node* itself reinterpreted as a raw
        // char), caught by an actual `read` round-trip test producing
        // garbage/truncated output instead of a real parse.
        GC_ROOT(node);  // settle runs the machine
        field head = settle(child_at(node, 0), NULL, eval_hnf);
        GC_UNROOT(1);
        *c = (char)child_at_c(head, 0);
    }
    return node;
}

// Every prior caller of this (prim_error, prim_writeFile/appendFile
// with string-literal arguments, prim_showStringLiteral) happened to
// only ever receive an already-fully-forced string, so this got away
// with reading node/character tags directly with no forcing of its own
// -- until read*Literal's own callers (readsPrec's real, lazy `lexDigits`/
// `span`-built strings, not literals) turned out to need it and
// segfaulted walking an unforced spine. settle() (runtime.h) is used at
// every spine step and on each character, same "chase FORWARD_TAG,
// redispatch through FUNCTION_TAG/CHOICE_TAG" fix as strictApply/cond/
// bindIO/(&)/ensureNotFree -- a no-op, and therefore still safe, for
// the already-forced strings every other caller passes.
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
RICE_CC void Prelude___DL_EX_EX_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_sp = sp;
    GC_ROOT(root);
    bool applied = strictApply(root, nf);
    GC_UNROOT(1);
    sp = rice_sp;
    if(!applied)
        RETURN();
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
        RETURN();
    MUSTTAIL return apply_hnf(root, sp);
}

// ----------------------------------------------------------------------
// IO plumbing: Rice's execution model has no separate IO-monad
// representation (see archetecture.md), so `bindIO m f` is exactly
// "evaluate m, then apply f to it", which is the same shape as `$!` above,
// just under a different name and without the FAIL/backtracking-stack
// bookkeeping IO code never needs. `returnIO x` is just `x` (returnIO's
// whole job is "wrap a value as an IO action," and there's no wrapper to
// build here).
// ----------------------------------------------------------------------

// bindIO :: IO a -> (a -> IO b) -> IO b -- m is the first parameter,
// f the second, so (matching every other node here, and the "forward
// storage" convention documented in runtime.h) m is child 0 and f is
// child 1.
// IO never backtracks: settling `m` (below) can dispatch a CHOICE_TAG
// node reached along the way (e.g. `m` itself is `x ? y`, or forcing
// one of its own arguments hits a choice somewhere inside), which
// pushes a real frame onto bt_stack via choose(). But apply_hnf below
// then overwrites `root` in place with f's result, permanently
// orphaning that choice from the reachable graph -- nothing will ever
// point back at it again. Left alone, the frame just sits on
// bt_stack, and a later top-level `undo(0)` (nf_all's "try another
// solution" loop) finds it, restores it, and re-runs nf() on a graph
// that never actually changed -- observed directly as a spurious
// second "SOLUTION: ()" for a plain `do`-block containing a `?`
// (see the regression test this fix adds). Recording the cutoff
// before doing any work and discarding (not restoring -- pop_to,
// unlike undo, never writes rhs back into lhs) everything above it
// once this call's whole dispatch (including running `f`, via
// apply_hnf) is done commits every choice made along the way, so
// nothing pushed during *this* bindIO call is ever visible to undo()
// again. This is also the soundness bar `catch`'s planned cutoff-based
// design needs bt_stack to actually meet.
// A single HNF() call is deliberately non-looping (see runtime.h),
// but an action built from further nested bindIO/`*>` calls (as any
// multi-statement `do`-block, or `putStr` recursing over a string,
// desugars to) WHNF-reduces one step at a time, landing on a FORWARD
// pointing at the *next* still-unrun action rather than a finished
// value -- the same reason apply_hnf's own dispatch loop chases
// FORWARD_TAG itself instead of trusting a single HNF() call. Without
// fully settling `m`, `f` (commonly `\_ -> next`, ignoring its
// argument -- the ordinary shape for IO () sequencing) would receive
// and discard that FORWARD reference, silencing every action still
// pending inside it before its side effects ever ran. settle() (same
// fix as strictApply/cond, above) does this: chases FORWARD_TAG and
// re-evaluates whatever that lands on, repeating
// until `m` is genuinely settled -- forward_hnf being a no-op means
// neither half alone is enough (a bare loop would stop cold on a
// freshly-reached FUNCTION_TAG/CHOICE_TAG; a bare evaluation never
// even starts chasing an already-FORWARD_TAG m). No nondet tracking
// needed here, unlike strictApply/cond: IO actions carry no
// FAIL/backtracking-stack bookkeeping at all (this function's own
// header comment), so there's nothing to trail either way.
//
// On the machine: bind_k settles m with frame [root, m, nondet, cutoff];
// then the frame becomes a commit frame [cutoff] while `apply f m` runs,
// and commit_k pops the trail back to the cutoff once root is in head
// normal form -- the same "after the whole dispatch" point as before.
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
    SLOT(3).i = size(bt_stack);
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
    pop_to(bt_stack, (int)cutoff);
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

// prim_putChar :: Char# -> IO () -- genuinely dispatched (not one of
// Rice.Codegen.C.PrimOps' inlined-expression primitives) specifically so
// this only runs when something actually forces it, same as getChar
// above: those primitives are all pure, so it's unobservable whether the
// C expression computing one runs at thunk-construction time or later,
// but putchar()'s side effect is exactly what bindIO's sequencing (see
// above) has to control the order of. Argument is the raw (unboxed)
// char replace_Prim.curry's own `putChar` already unwrapped via a
// `Char c'` case match before ever calling this.
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
// show*Literal: straightforward sprintf + toCurryString. read*Literal
// (the inverse direction) is not implemented yet.
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
    for (size_t i = 0; i < len; i++) { p = appendEscaped(p, s[i], '"'); }
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
//
// Was `nf(x)` followed by reading `x.n->symbol->tag` directly -- broken
// the same way strictApply's own pre-settle() bug was: `nf` takes its
// argument *by value* (a `field`, holding a pointer to the underlying
// Node), and internally chases FORWARD_TAG into its own *local*
// variable, mutating whatever it settles on in place but never writing
// that back into the caller's own `x`. If `x`'s own node ends up
// FORWARD_TAG (extremely common -- e.g. a dictionary-method case whose
// own result is itself a further call, redirected via set_forward
// rather than becoming a plain True/False constructor directly), the
// tag check right below sees FORWARD_TAG, matching neither FAIL_TAG nor
// Prelude__False_TAG, and silently falls through to the "must be True"
// branch -- discarding a real False. Confirmed directly: `(1 /= 1) &
// e` incorrectly forwarded to `e` instead of yielding False, traced via
// `--debug=high` to `/=`'s own dictionary-dispatch chain settling on a
// FORWARD_TAG node right where this reads its tag. `settle()` (like
// strictApply, cond, bindIO, prim_ioError already do) is exactly this
// fix, factored out: chase, re-force, repeat, *returning* the settled
// value instead of relying on in-place mutation the caller can't see.
// `x & y`: settle x (frame [root, x, nondet]); fail if it failed,
// False if it's False, otherwise root becomes y.
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
        fail(root);
    else if(x.n->symbol->tag == Prelude__False_TAG)
        set_Prelude__False(root, 0);
    else
        set_forward(root, child_at(root, 1));
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
// But we can still crate apply nodes (like `map apply`), so we need to handle it.
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
        set_forward(root, child_at(root, 1));
    else
        fail(root);
    RETURN();
}

// ----------------------------------------------------------------------
// ioError :: IOError -> IO _ (`ioError err = prim_ioError $## err`):
// raises a fatal error carrying the IOError's message. Every IOError
// constructor (IOError/UserError/FailError/NondetError) wraps exactly one
// String, so the message is always child 0; this skips replicating
// Show's per-constructor "i/o error: "/"user error: "/etc. prefix (no
// `catch` exists yet to make the distinction matter) and just reports the
// raw message.
// ----------------------------------------------------------------------

static void Prelude__prim_USioError_impl(void)
{
    field root = rice_root;
    field err = child_at(root, 0);
    // settle(), not a bare evaluation: child_at(err,0) right below needs
    // err genuinely resolved to a real IOError constructor, not a still-
    // pending tail call or (forward_hnf being a no-op) a FORWARD_TAG left
    // over from wherever err came from -- reading child_at(0) off a
    // forward wrapper itself would silently pull the wrapper's own
    // forward target, not the real IOError's message field. In practice
    // ioError's own definition (ioError err = prim_ioError $## err)
    // already forces err to ground normal form before this ever runs, so
    // this is defensive rather than independently observable -- but cheap
    // and consistent with strictApply/cond's own fix, just above. No
    // nondet tracking needed: error() below is exit(1), never backtracked
    // into, so there's nothing to trail.
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
// the other side, no narrowing needed. nf() recurses through the whole
// structure but doesn't collapse FORWARD_TAG chains (archetecture.md's
// "FORWARD_TAG collapsing" design), so this still has to chase forwards
// itself at every level, same as every other consumer.
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
        case R_INT:   return a.i == b.i;
        case R_CHAR:  return a.c == b.c;
        case R_FLOAT: return a.f == b.f;
        case R_PTR:   break;
    }
    return false;
}

// One pending comparison: a pointer pair (rep R_PTR) to unify, or a raw
// pair to compare by value.
typedef struct { field x, y; FieldRep rep; } UnifyPair;

static bool unify_step(field x0, field y0, bool* nondet)
{
    // Depth-first, children left to right -- the same order the recursive
    // version visited them in, so bindings happen in the same order. An
    // explicit work list keeps deep data (a long list) off the C stack.
    size_t cap = 64, n = 0;
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
        field x = p.x, y = p.y;
        *nondet |= x.n->nondet || y.n->nondet;
        while(x.n->symbol->tag == FORWARD_TAG) { x = child_at(x, 0); *nondet |= x.n->nondet; }
        while(y.n->symbol->tag == FORWARD_TAG) { y = child_at(y, 0); *nondet |= y.n->nondet; }

        // one side failed, we can't unify
        if(x.n->symbol->tag == FAIL_TAG || y.n->symbol->tag == FAIL_TAG)
        {
            ok = false;
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
                cap *= 2;
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
    // are trailed separately, so the order of the two frames doesn't matter.
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
// unlike unify_step, s is only evaluted to HNF.
// A free variable on the s side becomes a FORWARD to t directly
// (t can stay unevaluated);
// a free variable on the t side is narrowed
// to match s's already-known head constructor.
// Returns both success and whether any narrowing
// step touched a genuinely nondeterministic value, same "caller decides
// whether to trail" convention (trail_node) as strictApply/cond/(&) above.
// ----------------------------------------------------------------------

typedef struct { bool ok; bool nondet; } LazyResult;

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
    SLOT(7).i = size(bt_stack);
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
                save_copy(scruts);
                set_forward(scruts, SLOT(1));
                sp = frame_pop(sp);
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
        // Retry the pair from scratch, as the recursive version did.
        SLOT(2) = SLOT(0);
        SLOT(3) = SLOT(1);
        SLOT(4).i = 0;
        SLOT(5).i = 0;
        SLOT(6).i = false;
        SLOT(7).i = size(bt_stack);
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
        set_Prelude__True(root, 0);
    else
        fail(root);
    RETURN();
}

// ----------------------------------------------------------------------
// ensureNotFree :: a -> a -- real kics2 (Prelude.kics2.hs's own
// external_d_C_ensureNotFree) chases through Choice/Guard nodes and,
// on a genuinely unbound Free variable, *narrows* it (commits it to one
// of its type's constructors) before returning. That narrowing needs to
// know the variable's type -- which constructors to even try -- and
// this function, called generically as `Prelude__ensureNotFree_hnf`
// for every type alike, is never given one: unlike an ordinary
// FREE_TAG case-dispatch branch (runtime.c's generated pattern,
// `set_X_free`), which the *caller* generates once per concrete type it
// actually matches against, there is no single `set_X_free` this could
// call without knowing X. So this is a genuine architectural gap, not
// just an unwritten function -- but it's also very rarely hit in
// practice: `$#`/`ensureNotFree` don't appear anywhere in Rice's own
// replace_Prelude.curry/replace_Prim.curry, nor in the actual
// __KICS2__-branch Prelude.curry Rice's frontend compiles (only in that
// file's *other* CPP branches, for other backends) -- reachable here
// only if a Curry program calls `$#`/`ensureNotFree`/`ensureSpine`
// itself, not from anything Rice's own pipeline generates.
//
// Handles everything real kics2 does *except* the Free case: chases
// FORWARD_TAG and redispatches through FUNCTION_TAG/CHOICE_TAG via
// settle() (same as strictApply/cond/bindIO/prim_ioError), which
// covers Choice and Guard's own role here (both eventually resolve to
// a real tag through the ordinary CHOICE_TAG/FUNCTION_TAG dispatch a
// generated case ordinarily forces anyway). A settled FREE_TAG is
// passed through unchanged rather than narrowed -- correct whenever the
// caller only needed "some value to force", wrong if it specifically
// needed the result guaranteed non-free; no way to tell which from
// here.
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

// Reads the whole file at `path` into a fresh, NUL-terminated buffer
// the caller must free -- same NUL-terminated-C-string convention
// toCurryString/toCStr already assume throughout this file, so (as
// elsewhere here) an embedded NUL byte in the file's own content would
// truncate the Curry string built from it early. `mode` is fopen's own
// ("r" or "a+"/"w"/...) -- only ever called here with "r", but kept as
// a parameter rather than hardcoded since the caller already has to
// pick a fatal-error message either way.
static char* readWholeFile(const char* path, const char* what)
{
    FILE* f = fopen(path, "r");
    if(f == NULL)
    {
        char msg[512];
        snprintf(msg, sizeof(msg), "%s: %s: %s", what, path, strerror(errno));
        error(msg, make_Prelude___LP_RP(0));
    }
    size_t cap = 4096, len = 0;
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

// Shared by writeFile ("w", truncate) and appendFile ("a", append) --
// same fopen mode letter fwrite/fopen themselves use.
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
        char msg[512];
        snprintf(msg, sizeof(msg), "%s: %s: %s",
                 mode == 'w' ? "writeFile" : "appendFile", path, strerror(errno));
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

static void Prelude__prim_USwriteFile_impl(void)  { field root = rice_root; writeToFile(root, 'w'); }
static void Prelude__prim_USappendFile_impl(void) { field root = rice_root; writeToFile(root, 'a'); }

// ----------------------------------------------------------------------
// Deferred stubs: crash the program rather than silently fail.
// Real exception handling, and the parsing direction of literal show/read.
// ----------------------------------------------------------------------

static void Prelude__catch_impl(void) { field root = rice_root; error("catch not implemented yet", root); }

// ----------------------------------------------------------------------
// read*Literal: the inverse of show*Literal above -- each is a `ReadS a`
// (`String -> [(a, String)]`, the standard Haskell-style "parse a
// *prefix*, return what's left" convention: `[]` means no parse, one
// (value, rest) pair means the literal was found at the very start of
// the input). Every caller in the real Prelude (readsPrec's Char/Int/
// Float instances) already hands these a string `lex`/`lexDigits` cut
// down to exactly one token and only keeps a result whose own `rest` is
// empty, so a real prefix parser (rather than assuming the whole input
// is one bare literal) is correct for both that internal use and any
// direct external call.
//
// Escaping is the exact inverse of appendEscaped's own table (runtime.c,
// above show*Literal): same named escapes, same decimal \NNN fallback.
// ----------------------------------------------------------------------

static bool isAsciiDigit(char c) { return c >= '0' && c <= '9'; }

// Decodes the escape starting right after the backslash at `p` (not
// included), writes the decoded byte to `*out`, and returns how many
// bytes of `p` it consumed -- 0 means unrecognized/malformed.
static int parseEscape(const char* p, char* out)
{
    switch (*p)
    {
        case '\\': *out = '\\'; return 1;
        case '\'': *out = '\''; return 1;
        case '"':  *out = '"';  return 1;
        case 'a':  *out = '\a'; return 1;
        case 'b':  *out = '\b'; return 1;
        case 'f':  *out = '\f'; return 1;
        case 'n':  *out = '\n'; return 1;
        case 'r':  *out = '\r'; return 1;
        case 't':  *out = '\t'; return 1;
        case 'v':  *out = '\v'; return 1;
        default:
            if (isAsciiDigit(*p))
            {
                int val = 0, n = 0;
                while (n < 3 && isAsciiDigit(p[n])) { val = val * 10 + (p[n] - '0'); n++; }
                *out = (char)val;
                return n;
            }
            return 0;
    }
}

typedef struct { bool ok; char value; const char* rest; } CharParse;

static CharParse tryParseCharLiteral(const char* s)
{
    if (s[0] != '\'') return (CharParse){ false, 0, s };
    const char* p = s + 1;
    char c;
    if (*p == '\\')
    {
        int n = parseEscape(p + 1, &c);
        if (n == 0) return (CharParse){ false, 0, s };
        p += 1 + n;
    }
    else if (*p == '\0' || *p == '\'')
    {
        return (CharParse){ false, 0, s }; // empty '' or unterminated
    }
    else
    {
        c = *p;
        p += 1;
    }
    if (*p != '\'') return (CharParse){ false, 0, s };
    return (CharParse){ true, c, p + 1 };
}

typedef struct { bool ok; char* value; const char* rest; } StringParse;

// On success, `value` is a fresh malloc'd, NUL-terminated C string the
// caller must free.
static StringParse tryParseStringLiteral(const char* s)
{
    if (s[0] != '"') return (StringParse){ false, NULL, s };
    const char* p = s + 1;
    size_t cap = 64, len = 0;
    char* buf = (char*)malloc(cap);
    while (*p != '"')
    {
        if (*p == '\0') { free(buf); return (StringParse){ false, NULL, s }; }
        char c;
        if (*p == '\\')
        {
            int n = parseEscape(p + 1, &c);
            if (n == 0) { free(buf); return (StringParse){ false, NULL, s }; }
            p += 1 + n;
        }
        else
        {
            c = *p;
            p += 1;
        }
        if (len + 1 >= cap) { cap *= 2; buf = (char*)realloc(buf, cap); }
        buf[len++] = c;
    }
    buf[len] = '\0';
    return (StringParse){ true, buf, p + 1 };
}

typedef struct { bool ok; double value; const char* rest; } FloatParse;

static FloatParse tryParseFloatLiteral(const char* s)
{
    // Curry Float literal syntax always starts with a digit (the sign,
    // if any, is handled by readSigned, a layer up) -- checked
    // explicitly rather than just handing `s` to strtod, which would
    // also accept a leading sign/"nan"/"inf" text that isn't valid here.
    if (!isAsciiDigit(s[0])) return (FloatParse){ false, 0, s };
    char* end;
    double v = strtod(s, &end);
    if (end == s) return (FloatParse){ false, 0, s };
    return (FloatParse){ true, v, end };
}

// Every read*Literal _hnf below shares this shape: parse, then either
// `[]` (make_Prelude___LB_RB) or a one-element list holding the
// (value, rest) pair.
static field noParse(void) { return make_Prelude___LB_RB(0); }

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
    if (!isAsciiDigit(s[0]))
    {
        result = noParse();
    }
    else
    {
        char* p = s;
        long value = 0;
        while (isAsciiDigit(*p)) { value = value * 10 + (*p - '0'); p++; }
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
    field result = r.ok
      ? oneParse(make_Prelude__Char((field)(unsigned long)(unsigned char)r.value, 0), r.rest)
      : noParse();
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
    field result = r.ok ? oneParse(toCurryString(r.value), r.rest) : noParse();
    overwrite_root(root, result);
    if (r.ok) { free(r.value); }
    free(s);
}

static void Prelude__prim_USreadFloatLiteral_impl(void)
{
    field root = rice_root;
    GC_ROOT(root);  // toCStr runs the machine
    char* s = toCStr(child_at(root, 0));
    GC_UNROOT(1);
    FloatParse r = tryParseFloatLiteral(s);
    field result = r.ok
      ? oneParse(make_Prelude__Float((field)(double)r.value, 0), r.rest)
      : noParse();
    overwrite_root(root, result);
    free(s);
}

// ----------------------------------------------------------------------
// Machine entry points (runtime/machine.h). Each runs its C-convention
// implementation above, which may still evaluate subterms with nested
// eval_hnf calls, then returns to the frame on top of the machine stack.
// ----------------------------------------------------------------------

RICE_CC void Prelude__returnIO_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__returnIO_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__getChar_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__getChar_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USputChar_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USputChar_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USerror_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USerror_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USshowIntLiteral_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USshowIntLiteral_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USshowFloatLiteral_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USshowFloatLiteral_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USshowCharLiteral_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USshowCharLiteral_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USshowStringLiteral_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USshowStringLiteral_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__failed_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__failed_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USioError_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USioError_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__constrEq_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__constrEq_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USreadFile_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USreadFile_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USwriteFile_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USwriteFile_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USappendFile_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USappendFile_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__catch_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__catch_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USreadNatLiteral_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USreadNatLiteral_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USreadCharLiteral_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USreadCharLiteral_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USreadStringLiteral_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USreadStringLiteral_impl(); sp = rice_sp; RETURN(); }
RICE_CC void Prelude__prim_USreadFloatLiteral_hnf(union field root, Frame* sp) { GC_SAFE_POINT(root, sp); rice_root = root; rice_sp = sp; Prelude__prim_USreadFloatLiteral_impl(); sp = rice_sp; RETURN(); }
