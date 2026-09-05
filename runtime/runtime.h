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

// Boxed Int/Char/Float used to get their own hardcoded tag (all sharing the
// literal value 5) and a children[1] sentinel (INT_CTR/CHAR_CTR/FLOAT_CTR)
// to tell them apart, since a bare tag can't. That's gone -- see Symbol's
// `payload` field in node.h and archetecture.md's "Boxed primitives, and
// the Symbol.payload design": codegen gives the three box constructors an
// ordinary, dynamically-assigned tag like any other constructor, and sets
// `.payload` on their Symbol once, at the same call site that already
// emits `.tag`/`.arity`/`.name` for every constructor.

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
// child_at_v(r,i) is a ternary of two `union field` *values* -- never an
// lvalue in C (unlike C++, `?:` doesn't yield one even when both branches
// are lvalues), so `child_at_v(r,i) = v` doesn't compile. set_child_at
// needs its own, pointer-typed ternary to dereference and assign through.
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



#define NO_OPTS            0
#define PUSH_NONDET        1
#define EVAL_KNOWN_CALLS   2
#define EARLY_BACKTRACKING 3
// TEST == 0 return functions instead of evaluating them and always push
// TEST == 1 only push if nondet is set
// TEST == 2 evaluate known functions
// TEST == 3 early backtracking

// The backtracking stack can be used pretty much anywhere, so it almost has
// to be a global variable -- the only alternative is to pass it to every
// single function. Declared here (moved up from further down in this file)
// because push_node, right below, is the first of many functions in this
// header that reference it -- an extern declared only after its first use
// is an implicit-declaration error under -Wall/-Werror, previously unnoticed
// simply because nothing had compiled this file with real warnings on.
extern Stack* bt_stack;

// Used to print out the total number of memory allocations (see alloc() in
// memory.h). Same "declared before first use" reasoning as bt_stack above.
extern unsigned long mem;

// Forward declarations: push_node/fail_nf (right below) call these before
// their real definitions appear further down in this file (copy/save_copy
// in runtime.c; fail, static inline, further down in this file) -- without
// a declaration in scope first, this is an implicit function declaration,
// which -Wall/-Werror correctly rejects.
static inline void fail(union field root);
union field copy(union field node);
void save_copy(union field n);

#if TEST == NO_OPTS
// push a node on the backtracking stack
__attribute__((always_inline))
static inline void push_node(union field root, bool nondet)
{
    root.n->nondet = nondet;
    stack_push(bt_stack, root, copy(root), false);
}
#else
// push a node ot the backtracking stack
// if the non-det flat is set.
__attribute__((always_inline))
static inline void push_node(union field root, bool nondet)
{
    root.n->nondet = nondet;
    if(nondet)
    {
        stack_push(bt_stack, root, copy(root), false);
    }
}
#endif

// when reducing a node to normal form, if the child is FAIL, then the root
// should also be FAIL. Doesn't depend on which push_node variant is active
// above, so it's defined once, for every TEST level -- previously this only
// existed under TEST == NO_OPTS, but nf() calls it unconditionally.
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

// functions for manipulating curry strings
union field toCurryString(char* str);
void setCurryString(union field root, char* str);
char* toCStr(union field string);


static Symbol fail_symbol    = { .tag = FAIL_TAG,     .arity = 0, .name = "FAIL",    .hnf = &CTR_hnf };
static Symbol choice_symbol  = { .tag = CHOICE_TAG,   .arity = 2, .name = "?",       .hnf = &choice_hnf };
static Symbol forward_symbol = { .tag = FORWARD_TAG,  .arity = 1, .name = "->",      .hnf = &forward_hnf };
static Symbol free_symbol    = { .tag = FREE_TAG,     .arity = 0, .name = "free",    .hnf = &CTR_hnf };
static Symbol apply_symbol   = { .tag = FUNCTION_TAG, .arity = 0, .name = "apply",   .hnf = &apply_hnf };
// Boxed Int/Char/Float no longer have hardcoded Symbols here -- codegen
// generates them (Phase 1), an ordinary tag plus `.payload` set, like any
// other constructor. See the comment near FAIL_TAG above.

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

__attribute__((always_inline)) 
static inline union field make_forward(union field child)
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
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
    n.n->nondet = false;
    n.n->missing = 0;
    n.n->symbol = &choice_symbol;
    child_at(n, 0) = left;
    child_at(n, 1) = right;
    child_at(n, 2).i = 0;
    return n;
}


// Boxed Int/Char/Float make/set functions used to live here, hardcoded
// against int_symbol/char_symbol/float_symbol above. Deleted -- codegen
// (Phase 1) generates make__int/set__int/etc. against its own
// dynamically-assigned, .payload-tagged Symbols instead (Compile.PrimOps),
// so there's exactly one representation, not two. See the comment near
// FAIL_TAG above and archetecture.md's "Boxed primitives, and the
// Symbol.payload design".

__attribute__((always_inline))
static inline union field free_var()
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
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
