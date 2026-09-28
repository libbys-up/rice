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

void setCurryString(field root, char* str)
{
    memcpy(root.n, toCurryString(str).n, sizeof(Node));
}

// (:)'s children are forward-stored, same as any other ordinary
// constructor (child 0 the head, child 1 the tail -- Rice.Codegen.C.ToH's
// setRealChildren; not the reversed convention `apply`'s own missing-
// argument slots use, runtime.h's own note on that) -- this used to read
// them backwards, the same bug (and likely just as untested until now)
// as runtime.c's print_string/print_list/print_tuple.
char* toCStr(field string)
{
    field node = string;
    int len = 0;
    while(node.n->symbol->tag != Prelude___LB_RB_TAG)
    {
        node = child_at(node, 1); // tail
        len++;
    }

    char* cstr = (char*)malloc(len + 1);
    cstr[len] = '\0';

    node = string;
    for(int i = 0; i < len; i++)
    {
        field head = child_at(node, 0);
        cstr[i] = (char)head.n->children[0].c;
        node = child_at(node, 1);
    }
    return cstr;
}

// ----------------------------------------------------------------------
// Strict application: `f $! x`, `f $!! x`, `f $## x` -- evaluate the
// argument (to head normal form / normal form / ground normal form
// respectively) before applying f to it. All three share the same shape;
// only which forcing function runs differs.
// ----------------------------------------------------------------------

static void strictApply(field root, void (*force)(field))
{
    field f = child_at(root, 0);
    field x = child_at(root, 1);
    // force(x) alone can leave x sitting at FORWARD_TAG unread: forward_hnf
    // is a deliberate no-op (runtime.h's own note on it), so if x is
    // already a forward -- e.g. the result of some earlier collapse point
    // that wasn't safe to copy, the common case, since choose() itself
    // always produces one -- a single force() call never even reaches
    // whatever it points to, and the FAIL_TAG check right below would
    // silently inspect the wrapper instead of the real value. settle()
    // (runtime.h) is exactly this fix, factored out: chase, re-force,
    // repeat, accumulating nondet along the way rather than just reading
    // x's own -- necessary here specifically, not just belt-and-braces:
    // x can settle on a node (e.g. a FAIL_TAG reached by chasing through
    // a choice) whose own nondet flag was never itself touched by
    // choose(), only the choice node's was.
    bool nondet = false;
    x = settle(x, &nondet, force);
    if(nondet)
    {
        save_copy(root);
    }
    if(x.n->symbol->tag == FAIL_TAG)
    {
        fail(root);
    }
    else
    {
        set_apply1(root, f, x);
        apply_hnf(root);
    }
}

// HNF_SETTLE, not HNF: strictApply inspects x's tag directly right after
// forcing it, so a deferred tail call (OPT_TAIL_JUMP) needs draining all
// the way here, not just one hop -- same reasoning as nf/ground_nf
// (runtime.c), which is also why those two are safe to pass as `force`
// for $!!/$## below without any change of their own.
void Prelude___DL_EX_hnf(field root)    { strictApply(root, HNF_SETTLE); }
void Prelude___DL_EX_EX_hnf(field root) { strictApply(root, nf); }
void Prelude___DL_HT_HT_hnf(field root) { strictApply(root, ground_nf); }

// ----------------------------------------------------------------------
// IO plumbing: Rice's execution model has no separate IO-monad
// representation (see archetecture.md), so `bindIO m f` is exactly
// "evaluate m, then apply f to it", which is the same shape as `$!` above,
// just under a different name and without the FAIL/backtracking-stack
// bookkeeping IO code never needs. `returnIO x` is just `x` (returnIO's
// whole job is "wrap a value as an IO action," and there's no wrapper to
// build here).
// ----------------------------------------------------------------------

void Prelude__bindIO_hnf(field root)
{
    // bindIO :: IO a -> (a -> IO b) -> IO b -- m is the first parameter,
    // f the second, so (matching every other node here, and the "forward
    // storage" convention documented in runtime.h) m is child 0 and f is
    // child 1.
    field m = child_at(root, 0);
    field f = child_at(root, 1);
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
    // redispatches with HNF_SETTLE on whatever that lands on, repeating
    // until `m` is genuinely settled -- forward_hnf being a no-op means
    // neither half alone is enough (a bare loop would stop cold on a
    // freshly-reached FUNCTION_TAG/CHOICE_TAG; a bare HNF_SETTLE never
    // even starts chasing an already-FORWARD_TAG m). No nondet tracking
    // needed here, unlike strictApply/cond: IO actions carry no
    // FAIL/backtracking-stack bookkeeping at all (this function's own
    // header comment), so there's nothing to trail either way.
    m = settle(m, NULL, HNF_SETTLE);
    set_apply1(root, f, m);
    apply_hnf(root);
}

void Prelude__returnIO_hnf(field root)
{
    set_forward(root, child_at(root, 0));
}

void Prelude__getChar_hnf(field root)
{
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
void Prelude__prim_USputChar_hnf(field root)
{
    putchar((int)child_at_c(root, 0));
    set_Prelude___LP_RP(root, 0);
}

// ----------------------------------------------------------------------
// error :: String -> a -- the one primitive whose whole job already *is*
// reporting a fatal error, so it goes through runtime.h's own error()
// helper directly rather than a raw exit().
// ----------------------------------------------------------------------

void Prelude__prim_USerror_hnf(field root)
{
    char* msg = toCStr(child_at(root, 0));
    error(msg, root);
}

// ----------------------------------------------------------------------
// show*Literal: straightforward sprintf + toCurryString. read*Literal
// (the inverse direction) is not implemented yet.
// ----------------------------------------------------------------------

void Prelude__prim_USshowIntLiteral_hnf(field root)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%ld", child_at_i(root, 0));
    memcpy(root.n, toCurryString(buf).n, sizeof(Node));
}

void Prelude__prim_USshowFloatLiteral_hnf(field root)
{
    char buf[64];
    snprintf(buf, sizeof(buf), "%f", child_at_f(root, 0));
    memcpy(root.n, toCurryString(buf).n, sizeof(Node));
}

// Appends c's *derived-Show* escaped spelling to buf (which must have
// room for at least 4 more bytes: the longest single-character
// expansion, a decimal escape like "\127", is 4 bytes) and returns the
// new write position. `quote` is whichever of '\'' or '"' is the
// enclosing literal's own delimiter -- the one character that needs
// escaping in one context but not the other (a bare '"' is fine inside
// 'x', a bare '\'' is fine inside "..."; confirmed against real kics2's
// own `show` output for exactly this case). Named escapes match GHC's
// derived Show (\a\b\f\n\r\t\v, plus \\ and the delimiter itself);
// anything else non-printable (code < 32, or >= 127 for a plain 7-bit
// char) falls back to a decimal escape, same convention.
char* appendEscaped(char* buf, char c, char quote)
{
    if (c == '\\')       { *buf++ = '\\'; *buf++ = '\\'; }
    else if (c == quote) { *buf++ = '\\'; *buf++ = quote; }
    else if (c == '\a')  { *buf++ = '\\'; *buf++ = 'a'; }
    else if (c == '\b')  { *buf++ = '\\'; *buf++ = 'b'; }
    else if (c == '\f')  { *buf++ = '\\'; *buf++ = 'f'; }
    else if (c == '\n')  { *buf++ = '\\'; *buf++ = 'n'; }
    else if (c == '\r')  { *buf++ = '\\'; *buf++ = 'r'; }
    else if (c == '\t')  { *buf++ = '\\'; *buf++ = 't'; }
    else if (c == '\v')  { *buf++ = '\\'; *buf++ = 'v'; }
    else if (c < 32 || c >= 127)
    {
        buf += sprintf(buf, "\\%d", (int)(unsigned char)c);
    }
    else { *buf++ = c; }
    return buf;
}

void Prelude__prim_USshowCharLiteral_hnf(field root)
{
    char c = (char)child_at_c(root, 0);
    char buf[8];
    char* p = buf;
    *p++ = '\'';
    p = appendEscaped(p, c, '\'');
    *p++ = '\'';
    *p = '\0';
    memcpy(root.n, toCurryString(buf).n, sizeof(Node));
}

void Prelude__prim_USshowStringLiteral_hnf(field root)
{
    char* s = toCStr(child_at(root, 0));
    size_t len = strlen(s);
    // Worst case every byte expands to a 4-byte decimal escape, plus the
    // two surrounding quotes and the terminator.
    char* buf = (char*)malloc(4 * len + 3);
    char* p = buf;
    *p++ = '"';
    for (size_t i = 0; i < len; i++) { p = appendEscaped(p, s[i], '"'); }
    *p++ = '"';
    *p = '\0';
    memcpy(root.n, toCurryString(buf).n, sizeof(Node));
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
void Prelude___AN_hnf(field root)
{
    field x = child_at(root, 0);
    field y = child_at(root, 1);
    bool nondet = false;
    x = settle(x, &nondet, HNF_SETTLE);
    if(nondet)
    {
        save_copy(root);
    }
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
        set_forward(root, y);
    }
}

void Prelude__failed_hnf(field root)
{
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

void Prelude__apply_hnf(field root)
{
    field f = child_at(root, 0);
    field x = child_at(root, 1);
    set_apply1(root, f, x);
    apply_hnf(root);
}

void Prelude__cond_hnf(field root)
{
    field c = child_at(root, 0);
    field x = child_at(root, 1);
    // settle(), not a single HNF_SETTLE + ad-hoc chase: c's tag is
    // inspected directly below (True/FAIL/else), and the old chase loop
    // here only ever followed FORWARD_TAG without ever redispatching what
    // it landed on (forward_hnf is a no-op, but so is stopping cold on a
    // freshly-reached, still-unresolved CHOICE_TAG or FUNCTION_TAG) --
    // confirmed empirically: `cond (False ? True) 99` gave "No solutions
    // found" instead of "SOLUTION: 99", since neither alternative of the
    // choice ever actually got resolved via choose(), only chased past.
    // Same fix as strictApply just above: settle() chases and re-forces
    // until c is genuinely a value, accumulating nondet at every hop
    // (not just c's own final flag -- see strictApply's own note on why
    // that's not equivalent).
    bool nondet = false;
    c = settle(c, &nondet, HNF_SETTLE);
    if(nondet)
    {
        save_copy(root);
    }
    if(c.n->symbol->tag == FAIL_TAG)
    {
        fail(root);
    }
    else if(c.n->symbol->tag == Prelude__True_TAG)
    {
        set_forward(root, x);
    }
    else
    {
        fail(root);
    }
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

void Prelude__prim_USioError_hnf(field root)
{
    field err = child_at(root, 0);
    // settle(), not a bare HNF_SETTLE: child_at(err,0) right below needs
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
    err = settle(err, NULL, HNF_SETTLE);
    char* msg = toCStr(child_at(err, 0));
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
// ----------------------------------------------------------------------

static bool unify_step(field x, field y)
{
    while(x.n->symbol->tag == FORWARD_TAG) { x = child_at(x, 0); }
    while(y.n->symbol->tag == FORWARD_TAG) { y = child_at(y, 0); }

    // one side failed, we can't unify
    if(x.n->symbol->tag == FAIL_TAG || y.n->symbol->tag == FAIL_TAG)
    {
        return false;
    }

    //one side if free, set it to point to the other side
    if(x.n->symbol->tag == FREE_TAG)
    {
        save_copy(x);
        set_forward(x, y);
        return true;
    }
    if(y.n->symbol->tag == FREE_TAG)
    {
        save_copy(y);
        set_forward(y, x);
        return true;
    }

    // the constructors don't match, we fail.
    if(x.n->symbol->tag != y.n->symbol->tag)
    {
        return false;
    }

    // We have Int/Char/Float, make sure the values match.
    if(x.n->symbol->payload == PAYLOAD_INT)
    {
        return child_at_i(x, 0) == child_at_i(y, 0);
    }
    if(x.n->symbol->payload == PAYLOAD_CHAR)
    {
        return child_at_c(x, 0) == child_at_c(y, 0);
    }
    if(x.n->symbol->payload == PAYLOAD_FLOAT)
    {
        return child_at_f(x, 0) == child_at_f(y, 0);
    }
    
    // try to unify the children.
    for(unsigned int i = 0; i < x.n->symbol->arity; i++)
    {
        if(!unify_step(child_at_v(x, i), child_at_v(y, i)))
        {
            return false;
        }
    }
    return true;
}

void Prelude__constrEq_hnf(field root)
{
    field x = child_at(root, 0);
    field y = child_at(root, 1);
    nf(x);
    nf(y);
    if(unify_step(x, y))
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
// whether to save_copy" convention as strictApply/cond/(&) above.
// ----------------------------------------------------------------------

typedef struct { bool ok; bool nondet; } LazyResult;

static LazyResult lazy_unify_step(field s, field t)
{
    int n = size(bt_stack);
    (void)n; // only read under `#if OPT_SCOPED_BACKTRACK` below -- unused
             // (and otherwise -Werror'd as such) when that's off.
    bool nondet = false;

    field scruts = s;

    // put s into head normal form
    // FAIL: backtrack and return (probably wrong)
    // FREE: forward to t
    // FORWARD: follow chain
    // FUN: call HNF
    // otherwise we've hit a constructor
    // FORWARD
    bool done = false;
    while(!done)
    {
        nondet |= scruts.n->nondet;
        if(scruts.n->symbol->tag == FAIL_TAG)
        {
            // If we're doing early backtracking,
            // try undoing a choice we've made here.
            // If we haven't made a choice since starting, then we're stuck
            // so give up and return.
            #if OPT_SCOPED_BACKTRACK
            if(undo(n))
            {
                // tail call to lazy_unify_step.  We're done with out current call.
                return lazy_unify_step(s, t);
            }
            #endif
            return (LazyResult){ false, nondet };
        }
        // free variable: Save a copy, so we can undo the choice.
        else if(scruts.n->symbol->tag == FREE_TAG)
        {
            save_copy(scruts);
            set_forward(scruts, t);
            return (LazyResult){ true, nondet };
        }
        else if(scruts.n->symbol->tag == FORWARD_TAG)
        {
            scruts = child_at(scruts, 0);
        }
        // Evaluate s to HNF.
        // Even though this will give us a fully evaluated s,
        // it might be a forward, or fail, so we need to keep looping.
        else if(scruts.n->symbol->tag == FUNCTION_TAG)
        {
            HNF(scruts);
        }
        else
        {
            done = true;
        }
    }

    // Exactly the same as evaluating s.
    // this could maybe be its own function?
    field scrutt = t;
    done = false;
    while(!done)
    {
        nondet |= scrutt.n->nondet;
        if(scrutt.n->symbol->tag == FAIL_TAG)
        {
            #if OPT_SCOPED_BACKTRACK
            if(undo(n))
            {
                // Note: This might also backtrack s too.
                // I'm like 90% sure that's what we want.
                // but I wan't to write it down so I remember.
                return lazy_unify_step(s, t);
            }
            #endif
            return (LazyResult){ false, nondet };
        }
        else if(scrutt.n->symbol->tag == FREE_TAG)
        {
            save_copy(scrutt);
            set_free_constructor(scrutt, scruts.n->symbol);
            nondet = true;
        }
        else if(scrutt.n->symbol->tag == FORWARD_TAG)
        {
            scrutt = child_at(scrutt, 0);
        }
        else if(scrutt.n->symbol->tag == FUNCTION_TAG)
        {
            HNF(scrutt);
        }
        else
        {
            done = true;
        }
    }

    // Not the same constructor, we fail.
    // possibly early backtrack.
    if(scruts.n->symbol->tag != scrutt.n->symbol->tag)
    {
        #if OPT_SCOPED_BACKTRACK
        if(undo(n)) 
        {
            return lazy_unify_step(s, t);
        }
        #endif
        return (LazyResult){ false, nondet };
    }
    // We have a primitive value, so check to see if its the same one.
    // The typechecking will ensure that its the same type of primitive.
    if(scruts.n->symbol->payload == PAYLOAD_INT)
    {
        return (LazyResult){ child_at_i(scruts, 0) == child_at_i(scrutt, 0), nondet };
    }
    if(scruts.n->symbol->payload == PAYLOAD_CHAR)
    {
        return (LazyResult){ child_at_c(scruts, 0) == child_at_c(scrutt, 0), nondet };
    }
    if(scruts.n->symbol->payload == PAYLOAD_FLOAT)
    {
        return (LazyResult){ child_at_f(scruts, 0) == child_at_f(scrutt, 0), nondet };
    }

    // make sure all the children unify.
    for(unsigned int i = 0; i < scruts.n->symbol->arity; i++)
    {
        LazyResult r = lazy_unify_step(child_at_v(scruts, i), child_at_v(scrutt, i));
        nondet |= r.nondet;
        if(!r.ok)
        {
            #if OPT_SCOPED_BACKTRACK
            if(undo(n))
            {
                return lazy_unify_step(s, t);
            }
            #endif
            return (LazyResult){ false, nondet };
        }
    }
    return (LazyResult){ true, nondet };
}

void Prelude__nonstrictEq_hnf(field root)
{
    field x = child_at(root, 0);
    field y = child_at(root, 1);
    LazyResult r = lazy_unify_step(x, y);
    if(r.nondet)
    {
        save_copy(root);
    }
    if(r.ok)
    {
        set_Prelude__True(root, 0);
    }
    else
    {
        fail(root);
    }
}

// ----------------------------------------------------------------------
// Deferred stubs: crash the program rather than silently fail.
// error handling, the parsing direction of literal show/read, and file I/O.
// ----------------------------------------------------------------------

void Prelude__catch_hnf(field root)          { error("catch not implemented yet", root); }
void Prelude__ensureNotFree_hnf(field root)  { error("ensureNotFree not implemented yet", root); }
void Prelude__prim_USreadCharLiteral_hnf(field root)   { error("read*Literal not implemented yet", root); }
void Prelude__prim_USreadStringLiteral_hnf(field root) { error("read*Literal not implemented yet", root); }
void Prelude__prim_USreadNatLiteral_hnf(field root)    { error("read*Literal not implemented yet", root); }
void Prelude__prim_USreadFloatLiteral_hnf(field root)  { error("read*Literal not implemented yet", root); }
void Prelude__prim_USreadFile_hnf(field root)   { error("file I/O not implemented yet", root); }
void Prelude__prim_USwriteFile_hnf(field root)  { error("file I/O not implemented yet", root); }
void Prelude__prim_USappendFile_hnf(field root) { error("file I/O not implemented yet", root); }
