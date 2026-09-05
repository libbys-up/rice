// A deliberately minimal, *correct* subset of Prelude's external
// primitives -- NOT a replacement for external.c/Prelude_external.c's
// eventual Phase 2 rewrite (STATUS.md), but enough to *link* a program at
// all in the meantime.
//
// Why this exists: every constructor/function Symbol in a generated
// Prelude.h takes its `.hnf` function's *address* unconditionally, whether
// or not the compiled program ever actually calls it -- so linking
// requires every external Prelude primitive to have a real, addressable
// definition somewhere, not just the ones a given program happens to use.
// external.c/Prelude_external.c are the intended home for these but don't
// compile yet (confirmed bugs cataloged in STATUS.md's Phase 2 section);
// rather than block Phase 1's first end-to-end verification on that
// rewrite, this file provides its own small, independently-correct subset:
// real implementations for the primitives simple enough to get right
// immediately (string conversion, the strict-application operators, the
// IO plumbing actually needed to run anything, char/literal I/O), and
// honest `error(...)` stubs -- routed through the one central helper
// (STYLE_GUIDE.md's convention), not a raw `exit()` -- for the rest
// (`catch`, `(=:=)`-adjacent structural equality, file I/O, `read*Literal`),
// left for Phase 2 same as before.
//
// Depends on a generated Prelude.h being #included before this file (only
// meaningful linked once per whole program, same as external.c always
// assumed) -- mangled names below are Prelude's own, via Rice.Codegen.Names.

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
    while (*end != '\0') { end++; }

    field string = make_Prelude___LB_RB(0);
    while (end != str)
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

char* toCStr(field string)
{
    field node = string;
    int len = 0;
    while (node.n->symbol->tag != Prelude___LB_RB_TAG)
    {
        node = child_at(node, 0); // tail
        len++;
    }

    char* cstr = (char*)malloc(len + 1);
    cstr[len] = '\0';

    node = string;
    for (int i = 0; i < len; i++)
    {
        field head = child_at(node, 1);
        cstr[i] = (char)head.n->children[0].c;
        node = child_at(node, 0);
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
    force(x);
    if (x.n->nondet)
    {
        save_copy(root);
    }
    if (x.n->symbol->tag == FAIL_TAG)
    {
        fail(root);
    }
    else
    {
        set_apply1(root, f, x);
        apply_hnf(root);
    }
}

void Prelude___DL_EX_hnf(field root)    { strictApply(root, HNF); }
void Prelude___DL_EX_EX_hnf(field root) { strictApply(root, nf); }
void Prelude___DL_HT_HT_hnf(field root) { strictApply(root, ground_nf); }

// ----------------------------------------------------------------------
// IO plumbing -- Rice's execution model has no separate IO-monad
// representation (see archetecture.md), so `bindIO m f` is exactly
// "evaluate m, then apply f to it" -- the same shape as `$!` above, just
// under a different name and without the FAIL/backtracking-stack
// bookkeeping IO code never needs. `returnIO x` is just `x` (returnIO's
// whole job is "wrap a value as an IO action," and there's no wrapper to
// build here).
// ----------------------------------------------------------------------

void Prelude__bindIO_hnf(field root)
{
    field f = child_at(root, 0);
    field m = child_at(root, 1);
    HNF(m);
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
// show*Literal -- straightforward sprintf + toCurryString. read*Literal
// (the inverse direction) is not implemented yet -- stubbed below.
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

void Prelude__prim_USshowCharLiteral_hnf(field root)
{
    char buf[2] = { (char)child_at_c(root, 0), '\0' };
    memcpy(root.n, toCurryString(buf).n, sizeof(Node));
}

void Prelude__prim_USshowStringLiteral_hnf(field root)
{
    char* s = toCStr(child_at(root, 0));
    memcpy(root.n, toCurryString(s).n, sizeof(Node));
    free(s);
}

// ----------------------------------------------------------------------
// (&) -- "committed"/concurrent conjunction (`x & y`, both must reduce to
// True). Real Curry implementations can evaluate both sides concurrently;
// Rice has no concurrency yet, so this is sequential, exactly like (&&)'s
// own real, non-external Prelude definition (`True && x = x`) -- same
// result for any terminating pair of arguments, just without the
// interleaving a concurrent evaluator would give a non-terminating one.
//
// failed -- fails unconditionally; already exactly this simple in every
// reference implementation read this session.
// ----------------------------------------------------------------------

void Prelude___AN_hnf(field root)
{
    field x = child_at(root, 0);
    field y = child_at(root, 1);
    nf(x);
    if (x.n->nondet)
    {
        save_copy(root);
    }
    if (x.n->symbol->tag == FAIL_TAG)
    {
        fail(root);
    }
    else if (x.n->symbol->tag == Prelude__False_TAG)
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
// Deferred to Phase 2 (STATUS.md) -- honest stubs, not silent wrong
// behavior: structural equality (needs a unify-like deep comparison),
// catch (needs real exception handling), file I/O, and read*Literal (the
// parsing direction).
// ----------------------------------------------------------------------

void Prelude__catch_hnf(field root)          { error("catch not implemented yet", root); }
void Prelude__constrEq_hnf(field root)       { error("constrEq not implemented yet", root); }
void Prelude__nonstrictEq_hnf(field root)    { error("nonstrictEq not implemented yet", root); }
void Prelude__ensureNotFree_hnf(field root)  { error("ensureNotFree not implemented yet", root); }
void Prelude__prim_USreadCharLiteral_hnf(field root)   { error("read*Literal not implemented yet", root); }
void Prelude__prim_USreadStringLiteral_hnf(field root) { error("read*Literal not implemented yet", root); }
void Prelude__prim_USreadNatLiteral_hnf(field root)    { error("read*Literal not implemented yet", root); }
void Prelude__prim_USreadFloatLiteral_hnf(field root)  { error("read*Literal not implemented yet", root); }
void Prelude__prim_USreadFile_hnf(field root)   { error("file I/O not implemented yet", root); }
void Prelude__prim_USwriteFile_hnf(field root)  { error("file I/O not implemented yet", root); }
void Prelude__prim_USappendFile_hnf(field root) { error("file I/O not implemented yet", root); }
