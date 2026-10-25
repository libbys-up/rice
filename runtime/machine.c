#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "machine.h"
#include "runtime.h"

union field  rice_root;
Frame*       rice_sp;
union field* rice_stack_lo;
union field* rice_stack_hi;

// Initial stack size, in words (1 MiB). It doubles as needed.
#define INITIAL_STACK_WORDS ((size_t)1 << 17)

// This is the code to return from the machine to C.
// machine_run pushes a sentinel frame at the bottom of each run.
// When the computation finishes, the last RETURN() jumps here.
//
// Everything between machine_run's call `code(x, base)` and here was a musttail jump,
// so there are no C frames in between.
// That means our plain `return` returns from that call in machine_run.
// sp only lives in a register, so we copy it into rice_sp for machine_run first.
static RICE_CC void sentinel_code(union field _root, Frame* sp)
{
    (void)_root;
    rice_sp = sp;
    return;
}

// Stack frame to get back to C code.  We don't need any slots, just the sentinel code.
static const FrameInfo sentinel_info =
    { .code = sentinel_code, .size = 0, .reps = NULL, .name = "sentinel" };

/* Create the machine
 *  * make the initial stack
 *  * set low/hi pointers for stack
 *  * set sp
 */
void machine_init(void)
{
    rice_stack_lo = (union field*)malloc(INITIAL_STACK_WORDS * sizeof(union field));

    // we failed to make the stack, give up and die.
    if(rice_stack_lo == NULL)
    {
        fprintf(stderr, "Error: can't allocate the evaluation stack\n");
        exit(1);
    }

    rice_stack_hi = rice_stack_lo + INITIAL_STACK_WORDS;

    // sp points to the top of the stack and works down.
    rice_sp = (Frame*)rice_stack_hi;
}


/* Grow the stack so that it's at least as big as `words`.
 * Since we double the stack each time, we might overshoot `words`.
 */
Frame* machine_grow(Frame* sp, size_t words)
{
    // vector growing.
    size_t old_cap = (size_t)(rice_stack_hi - rice_stack_lo);
    size_t used    = (size_t)machine_depth(sp);
    size_t new_cap = old_cap * 2;

    // double the size until we're at least `words` high
    while(new_cap - used < words)
    {
        new_cap *= 2;
    }

    // bottom address of the stack
    union field* lo = (union field*)malloc(new_cap * sizeof(union field));

    // We didn't get memory, give up!
    if(lo == NULL)
    {
        fprintf(stderr, "Error: evaluation stack overflow (%zu words)\n", new_cap);
        exit(1);
    }

    // Frames sit at the high end; keep them there.
    union field* hi = lo + new_cap;

    // copy old stack into new stack, and free old stack.
    // The stack grows down, so our current position is the top,
    // and move down however many words we've used.
    memcpy(hi - used, (union field*)sp, used * sizeof(union field));
    free(rice_stack_lo);

    // store new stack
    rice_stack_lo = lo;
    rice_stack_hi = hi;

    return (Frame*)(hi - used);
}

/* start the machine from C code.
 * We're calling `code` on root `x`
 */
void machine_run(Code code, union field x)
{
    union field saved_root = rice_root;

    // We still need x for the error message below.
    GC_ROOT(x);

    // Each run gets its own sentinel, so nested runs each return to their own machine_run.
    Frame* base = frame_push(rice_sp, &sentinel_info);

    ptrdiff_t depth = machine_depth(base);

    // call our hnf function with our stack
    code(x, base);

    // We've computed x, so it's no longer needed for garbage collection
    GC_UNROOT(1);
    
    // Check to make sure the stack balanced out.
    // If it didn't, something went wrong with evaluation and we need to debug.
    // We compare depths, not pointers, because the stack may have moved (machine_grow).
    if(machine_depth(rice_sp) != depth || rice_sp->info != &sentinel_info)
    {
        fprintf(stderr, "Error: evaluation stack unbalanced after evaluating %s\n",
                x.n->symbol->name);
        exit(1);
    }

    // restore stack pointer and root registers
    rice_sp = frame_pop(rice_sp);
    rice_root = saved_root;
}

// simple wrapper for machine_run
void eval_hnf(union field x)
{
    // Run the hnf function with root x.
    // This is the equivalent of
    // x.n->symbol->hnf(x)
    // from before
    machine_run(x.n->symbol->hnf, x);
}

/* print everything in the machine stack in the format
 * machine stack (K words):
 * [frameName1 param1 param2 ... ]
 * [frameName2 ...]
 * ...
 */
void print_machine_stack(void)
{
    printf("machine stack (%td words):\n", machine_depth(rice_sp));

    // loop over each stack frame and print it
    for(Frame* f = rice_sp; (union field*)f < rice_stack_hi;
        f = (Frame*)((union field*)f + 1 + f->info->size))
    {
        printf("  %s[", f->info->name);
        for(unsigned short i = 0; i < f->info->size; i++)
        {
            if(i > 0)
            {
                printf(", ");
            }
            print_field(f->slots[i], field_rep(f->info->reps,i));
        }
        printf("]\n");
    }
}
