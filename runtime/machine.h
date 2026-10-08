#ifndef MACHINE_H
#define MACHINE_H

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

#define MUSTTAIL __attribute__((musttail))

// Static description of one kind of frame: what runs when the frame is
// returned to, and the layout of its slots (node.h's FieldRep, one per
// slot; NULL means every slot is a pointer). The GC traces a frame's
// R_PTR slots through `reps`, exactly as it traces a node's children
// through Symbol.reps.
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

// The machine's registers are the two arguments of every piece of machine
// code: `root`, the node being reduced, and `sp`, the top frame. The stack
// grows downward: frames occupy [sp, rice_stack_hi), the newest at the
// lowest address, so popping a frame only needs its own size.
//
// rice_root and rice_sp are their copies for C code: machine code stores
// them before calling C code that might run the machine (a C-convention
// runtime body, nf, ...), and a machine run stores its final sp in
// rice_sp when it returns to C. Everywhere else they may be stale.
//
// A nested run can grow the stack, which moves it, so the machine code
// that made the C call must reload `sp = rice_sp;` afterwards: machine_run
// leaves rice_sp at the caller's top frame, wherever it now is.
extern union field  rice_root;
extern Frame*       rice_sp;
extern union field* rice_stack_lo;
extern union field* rice_stack_hi;

void machine_init(void);

// Makes room for at least `words` more words below the top frame `sp`, and
// returns the top frame's new address. Moves the stack, so any other
// Frame* is stale afterwards.
Frame* machine_grow(Frame* sp, size_t words);

// Pushes a frame with every slot zeroed (a NULL pointer slot is always
// safe to trace) and returns the new top frame. Use as
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

// Pops the top frame: `sp = frame_pop(sp);`.
static inline Frame* frame_pop(Frame* sp)
{
    return (Frame*)((union field*)sp + 1 + sp->info->size);
}

// Slot i of the top frame (the local `sp`).
#define SLOT(i) (sp->slots[i])

// Return to the top frame's code. The root register carries nothing on a
// return: continuations find their state in their own frames.
#define NO_ROOT ((union field){ .n = NULL })
#define RETURN() MUSTTAIL return sp->info->code(NO_ROOT, sp)

// How many words of the stack are in use below `sp`: a position that
// survives machine_grow, unlike a Frame*.
static inline ptrdiff_t machine_depth(Frame* sp)
{
    return rice_stack_hi - (union field*)sp;
}

// Runs the machine on x until x is in head normal form, then returns to
// the C caller. Nested calls are allowed (each costs one C frame); the
// machine's own evaluation doesn't use the C stack.
void eval_hnf(union field x);

// Runs machine code `code` with rice_root = x until it returns, the same
// way eval_hnf runs x's own code. eval_hnf(x) is
// machine_run(x.n->symbol->hnf, x).
void machine_run(Code code, union field x);

// Prints the frame stack, top first, for --debug.
void print_machine_stack(void);

#endif // MACHINE_H
