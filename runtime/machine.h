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

// The machine's registers.
//   rice_root   the node the running code is rewriting (`root`).
//   rice_sp     the top frame. The stack grows downward: frames occupy
//               [rice_sp, rice_stack_hi), the newest at the lowest
//               address, so popping a frame only needs its own size.
extern union field  rice_root;
extern Frame*       rice_sp;
extern union field* rice_stack_lo;
extern union field* rice_stack_hi;

void machine_init(void);

// Makes room for at least `words` more words below the top frame. Moves
// the stack, so any Frame* other than rice_sp is stale afterwards.
void machine_grow(size_t words);

// Pushes a frame with every slot zeroed (a NULL pointer slot is always
// safe to trace) and returns it.
static inline Frame* frame_push(const FrameInfo* info)
{
    size_t words = 1 + (size_t)info->size;
    if((union field*)rice_sp - rice_stack_lo < (ptrdiff_t)words)
    {
        machine_grow(words);
    }
    Frame* f = (Frame*)((union field*)rice_sp - words);
    f->info = info;
    for(unsigned short i = 0; i < info->size; i++)
    {
        f->slots[i].n = NULL;
    }
    rice_sp = f;
    return f;
}

static inline void frame_pop(void)
{
    rice_sp = (Frame*)((union field*)rice_sp + 1 + rice_sp->info->size);
}

// Slot i of the top frame.
#define SLOT(i) (rice_sp->slots[i])

// Return to the top frame's code.
#define RETURN() MUSTTAIL return rice_sp->info->code()

// How many words of the stack are in use: a position that survives
// machine_grow, unlike a Frame*.
static inline ptrdiff_t machine_depth(void)
{
    return rice_stack_hi - (union field*)rice_sp;
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
