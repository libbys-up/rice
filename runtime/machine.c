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

// The bottom frame of each machine run. Returning to it records the
// machine's stack pointer for the C code that started the run
// (machine_run), then returns to it.
static RICE_CC void sentinel_code(union field root, Frame* sp)
{
    (void)root;
    rice_sp = sp;
    return;
}

static const FrameInfo sentinel_info =
    { .code = sentinel_code, .size = 0, .reps = NULL, .name = "sentinel" };

void machine_init(void)
{
    rice_stack_lo = (union field*)malloc(INITIAL_STACK_WORDS * sizeof(union field));
    if(rice_stack_lo == NULL)
    {
        fprintf(stderr, "Error: can't allocate the evaluation stack\n");
        exit(1);
    }
    rice_stack_hi = rice_stack_lo + INITIAL_STACK_WORDS;
    // An empty stack: the "top frame" is just past the end. Nothing reads
    // through rice_sp until the first frame_push.
    rice_sp = (Frame*)rice_stack_hi;
}

Frame* machine_grow(Frame* sp, size_t words)
{
    size_t old_cap = (size_t)(rice_stack_hi - rice_stack_lo);
    size_t used    = (size_t)machine_depth(sp);
    size_t new_cap = old_cap * 2;
    while(new_cap - used < words)
    {
        new_cap *= 2;
    }
    union field* lo = (union field*)malloc(new_cap * sizeof(union field));
    if(lo == NULL)
    {
        fprintf(stderr, "Error: evaluation stack overflow (%zu words)\n", new_cap);
        exit(1);
    }
    // Frames sit at the high end; keep them there.
    union field* hi = lo + new_cap;
    memcpy(hi - used, (union field*)sp, used * sizeof(union field));
    free(rice_stack_lo);
    rice_stack_lo = lo;
    rice_stack_hi = hi;
    return (Frame*)(hi - used);
}

void machine_run(Code code, union field x)
{
    union field saved_root = rice_root;
    GC_ROOT(x);  // for the error message below
    Frame* base = frame_push(rice_sp, &sentinel_info);
    ptrdiff_t depth = machine_depth(base);
    code(x, base);
    GC_UNROOT(1);
    // sentinel_code stored the machine's final sp in rice_sp.
    if(machine_depth(rice_sp) != depth || rice_sp->info != &sentinel_info)
    {
        fprintf(stderr, "Error: evaluation stack unbalanced after evaluating %s\n",
                x.n->symbol->name);
        exit(1);
    }
    rice_sp = frame_pop(rice_sp);
    rice_root = saved_root;
}

void eval_hnf(union field x)
{
    machine_run(x.n->symbol->hnf, x);
}

void print_machine_stack(void)
{
    printf("machine stack (%td words):\n", machine_depth(rice_sp));
    for(Frame* f = rice_sp; (union field*)f < rice_stack_hi;
        f = (Frame*)((union field*)f + 1 + f->info->size))
    {
        printf("  %s[", f->info->name);
        for(unsigned short i = 0; i < f->info->size; i++)
        {
            if(i > 0)
                printf(", ");
            FieldRep r = f->info->reps ? (FieldRep)f->info->reps[i] : R_PTR;
            print_field(f->slots[i], r);
        }
        printf("]\n");
    }
}
