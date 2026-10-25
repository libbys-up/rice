#ifndef MACHINE_H
#define MACHINE_H

// Since C has a finite stack determined by the OS,
// we need to have our own stack when running curry programs.
// Otherwise, each function call can push a stack frame,
// and we'll run out of stack space.
//
// TCO (Tail Call Optimization) can alleviate a lot of this,
// but we can genuinely have recursive loops that are not tail calls,
// foldr is a good example of this.
//
// Instead we're going to make our own stack.
// This stack will consist of continuation frames.
// any code like
// code...
// int x = f(args)
// code...
// can be transformed into a continuation with
// code...
// f(args, \x -> code...)
//
// now f is in tail position and TCO can apply.
// so a return statement in f is really just a call to our continuation.
//
// We also have a RETURN() macro which will functionally act as our return statement,
// but in reality its calling our continuation.
//
//
// The evaluation machine: Rice's own stack of continuation frames, so that
// evaluating deeply nested expressions doesn't grow the C stack. See
// src/explicit-stack-plan.md for the design.
//
// Machine code (generated `_hnf` functions, case blocks, and runtime
// routines) transfers control only by guaranteed tail calls (MUSTTAIL).
// "Returning" means jumping to the code of the frame on top of the stack
// (RETURN). The bottom of each run of the machine is a sentinel frame
// whose code returns to C, which is how eval_hnf gets control back.

#include <stddef.h>
#include "node.h"

// This forces the function call to be a tail call
// (it's a compiler error if it can't be one),
// and it guarantees that gcc/clang will do tail call optimization,
// even at -O0.
// It also requires the caller and callee to have the same signature.
// That's why every piece of machine code has the type Code (node.h),
// even continuations that ignore their root argument.
#define MUSTTAIL __attribute__((musttail))

// Static description of a continuation frame.
//  * code: a pointer to the code to run when we return
//  * size: how many slots we need to keep around (not counting the header word).
//          This is the state the continuation needs, not the function's arity.
//  * reps: the FieldRep of each slot, so the garbage collector can find the pointers.
//          NULL means every slot is a pointer.
//  * name: the name of the continuation, for print_machine_stack.
//
// One function can have several kinds of frame.
// bindIO has one frame while it evaluates m, and a different one while f runs.
//
// You can think of this like a normal stack frame in C.
// code is the return address
// size and reps are the info about the caller save registers.
// the slots in Frame are the real caller save registers.
//
// This is similar to GHC's InfoTable.
typedef struct FrameInfo
{
    Code code;
    unsigned short size;
    const unsigned char* reps;
    const char* name;
} FrameInfo;

// A frame is one header word (its FrameInfo) followed by `info->size`
// slots, laid out in the stack's own array of words.
typedef struct Frame
{
    const FrameInfo* info;
    union field slots[];
} Frame;

_Static_assert(sizeof(const FrameInfo*) == sizeof(union field),
               "a frame header must be exactly one stack word");

// * root: the root of the current node we're reducing
// * sp: the current top of stack
// These will be passed into every function, so they should be kept in registers.
//
// The stack grows down.
// This is mostly convention, but it means sp points straight at the top frame's header,
// so Frame can be a plain struct and popping a frame only needs its own size.
// This does mean we have to malloc and copy instead of getting to use realloc.
//
// rice_root and rice_sp are copies of these for C code.
// root and sp only live in registers (function arguments), and C code can't see those.
// So machine code stores them here before calling C code that might run the machine,
// and a run of the machine stores its final sp in rice_sp when it returns to C.
// Everywhere else they may be stale.
// rice_stack_lo and rice_stack_hi give the bounds of the current stack.
//
// A nested run can grow the stack, which moves it, so the machine code
// that made the C call must reload `sp = rice_sp;` afterwards: machine_run
// leaves rice_sp at the caller's top frame, wherever it now is.
//
extern union field  rice_root;
extern Frame*       rice_sp;
extern union field* rice_stack_lo;
extern union field* rice_stack_hi;

// Sets up the stack.
void machine_init(void);

// Makes room for more words on the stack.
// The number of new words is given by `words`.
// `sp` is the current top of the stack.
// returns the new top of stack.
// This moves the stack, so old Frame* are now invalid.
Frame* machine_grow(Frame* sp, size_t words);

// Pushes a frame with every slot zeroed.
// (a NULL pointer slot is always safe to trace)
// Then we return the new top of stack.
// Use as:
// `sp = frame_push(sp, &info);`.
static inline Frame* frame_push(Frame* sp, const FrameInfo* info)
{
    size_t words = 1 + (size_t)info->size;
    if((union field*)sp - rice_stack_lo < (ptrdiff_t)words)
    {
        sp = machine_grow(sp, words);
    }
    Frame* f = (Frame*)((union field*)sp - words);
    f->info = info;
    for(unsigned short i = 0; i < info->size; i++)
    {
        f->slots[i].n = NULL;
    }
    return f;
}

// Gets the address of the frame under the top frame of the stack.
// This doesn't change anything; the caller pops by assigning:
// `sp = frame_pop(sp)`
// Read any SLOTs you need first, because the next push will overwrite them.
static inline Frame* frame_pop(Frame* sp)
{
    return (Frame*)((union field*)sp + 1 + sp->info->size);
}

// Slot i of the top frame (the local `sp`).
#define SLOT(i) (sp->slots[i])

// A null root used for returning.
// A continuation isn't being asked to reduce a new node,
// so it gets its own root back out of its frame instead.
#define NO_ROOT ((union field){ .n = NULL })

// This is our return statement.
// We look up the continuation and call the code.
// We don't have root when we return (its on the stack)
#define RETURN() MUSTTAIL return sp->info->code(NO_ROOT, sp)

// How many words of the stack are in use below `sp`.
static inline ptrdiff_t machine_depth(Frame* sp)
{
    return rice_stack_hi - (union field*)sp;
}

// Runs the machine on x until x is in head normal form,
// then returns to the C caller.
// This is how C code evaluates something on the machine.
// It's really a thin wrapper around machine_run.
void eval_hnf(union field x);

// Runs machine code `code` with rice_root = x until it returns,
// the same way eval_hnf runs x's own code. eval_hnf(x) is
// machine_run(x.n->symbol->hnf, x).
void machine_run(Code code, union field x);

// Prints the frame stack, top first, for --debug.
void print_machine_stack(void);

#endif // MACHINE_H
