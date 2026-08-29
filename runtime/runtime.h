#ifndef RUNTIME_H
#define RUNTIME_H

#include <stdlib.h>
#include "node.h"
#include "stack.h"
#include "debug.h"
#include "memory.h"

#define FAIL_TAG     0
#define FUNCTION_TAG 1
#define CHOICE_TAG   2
#define FORWARD_TAG  3
#define FREE_TAG     4

// tages used for primitive types
#define _int_TAG     5
#define _float_TAG   5
#define _char_TAG    5



#define INT_CTR      -1
#define FLOAT_CTR    -2
#define CHAR_CTR     -3

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
#define child_at_v(r, i) (i < 3 ? r.n->children[i] : r.n->children[3].a[i-3])
// I don't think I need this.
#define set_child_at(r, i, v) child_at_v(r,i) = v



__attribute__((always_inline)) 
static inline unsigned char TAG(union field root)
{
    return root.n->symbol->tag;
}
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

#if TEST == NO_OPTS
// push a node on the backtracking stack
__attribute__((always_inline)) 
static inline void push_node(union field root, bool nondet)
{
    root.n->nondet = nondet;
    stack_push(bt_stack, root, copy(root), false);
}
// when reducing a node to normal form
// if the child is FAIL, then the root should also be fail.
__attribute__((always_inline)) 
static inline void fail_nf(union field child, union field root)
{
    root.n->nondet |= child.n->nondet;
    save_copy(root);
    fail(node);
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
static Symbol int_symbol     = { .tag = _int_TAG,     .arity = 1, .name = "int",     .hnf = &CTR_hnf };
static Symbol char_symbol    = { .tag = _char_TAG,    .arity = 1, .name = "char",    .hnf = &CTR_hnf };
static Symbol float_symbol   = { .tag = _float_TAG,   .arity = 1, .name = "float",   .hnf = &CTR_hnf };
static Symbol apply_symbol   = { .tag = FUNCTION_TAG, .arity = 0, .name = "apply",   .hnf = &apply_hnf };

// the backtracking stack can be used pretty much anywhere
// So it almost has to be a global variable.
// The only alternative is to pass it to every single function.
extern Stack* bt_stack;

// used to print out the total number of memory allocations.
extern unsigned long mem;

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


__attribute__((always_inline)) 
static inline void set_int(union field root, long i, int missing)
{
    root.n->missing = 0;
    root.n->symbol = &int_symbol;
    root.n->missing = missing;
    child_at_i(root,0) = i;
    child_at_i(root,1) = INT_CTR;
    child_at_n(root,2) = NULL;
    root.n->children[3].a = NULL;
}
__attribute__((always_inline)) 
static inline void set_int_free(union field root, long i, int missing)
{
    set_int(root,i,missing);
    root.n->nondet = true;
}

__attribute__((always_inline)) 
static inline union field make_int(long i, int missing)
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
    n.n->symbol = &int_symbol;
    n.n->missing = missing;
    child_at_i(n,0) = i;
    child_at_i(n,1) = INT_CTR;
    return n;
}
__attribute__((always_inline)) 
static inline union field make_int_free(long i, int missing)
{
    union field n = make_int(i,missing);
    n.n->nondet = true;
    return n;
}

__attribute__((always_inline)) 
static inline void set_char(union field root, long c, int missing)
{
    root.n->missing = 0;
    root.n->symbol = &char_symbol;
    root.n->missing = missing;
    child_at_c(root,0) = c;
    child_at_i(root,1) = CHAR_CTR;
    child_at_n(root,2) = NULL;
    root.n->children[3].a = NULL;
}
__attribute__((always_inline)) 
static inline void set_char_free(union field root, long c, int missing)
{
    set_char(root,c,missing);
    root.n->nondet = true;
}

__attribute__((always_inline)) 
static inline union field make_char(long c, int missing)
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
    n.n->symbol = &char_symbol;
    n.n->missing = missing;
    child_at_c(n,0) = c;
    child_at_i(n,1) = CHAR_CTR;
    return n;
}
__attribute__((always_inline)) 
static inline union field make_char_free(long c, int missing)
{
    union field n = make_char(c,missing);
    n.n->nondet = true;
    return n;
}

__attribute__((always_inline)) 
static inline void set_float(union field root, double f, int missing)
{
    root.n->missing = 0;
    root.n->symbol = &float_symbol;
    root.n->missing = missing;
    child_at_f(root,0) = f;
    child_at_i(root,1) = FLOAT_CTR;
    child_at_n(root,2) = NULL;
    root.n->children[3].a = NULL;
}
__attribute__((always_inline)) 
static inline void set_float_free(union field root, long f, int missing)
{
    set_float(root,f,missing);
    root.n->nondet = true;
}

__attribute__((always_inline)) 
static inline union field make_float(double f, int missing)
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
    n.n->symbol = &float_symbol;
    n.n->missing = missing;
    child_at_f(n,0) = f;
    child_at_i(n,1) = FLOAT_CTR;
    return n;
}
__attribute__((always_inline)) 
static inline union field make_float_free(long f, int missing)
{
    union field n = make_float(f,missing);
    n.n->nondet = true;
    return n;
}


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
