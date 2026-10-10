#ifndef GC_H
#define GC_H

// The copying collector (gc.c, src/gc-plan.md). Allocation never collects;
// a collection happens only at a safe point -- the entry of every `_hnf`
// function -- once enough has been allocated since the last one. At that
// point the live pointers are exactly: the `root` argument, the frames on
// the machine stack (traced through FrameInfo.reps), the trail, and the C
// roots registered below.

#include <stddef.h>
#include "node.h"
#include "machine.h"
#include "memory.h"

// Collect when this many bytes have been allocated since the last
// collection. 0 under GC_STRESS: collect at every safe point.
extern size_t rice_heap_threshold;

// Copies everything reachable from `root`, the frames from `sp` up, the
// trail and the C roots into fresh chunks, frees the old ones, and returns
// root's new address. Frames, trail entries and C roots are updated in
// place.
union field gc_collect(union field root, Frame* sp);

#define GC_SAFE_POINT(root, sp)                                  \
    do {                                                         \
        if (rice_heap_since_gc > rice_heap_threshold)            \
            (root) = gc_collect((root), (sp));                   \
    } while (0)

// C roots: C code that keeps node pointers in locals across a call that
// can run the machine (eval_hnf, nf, settle, toCStr, ...) registers each
// one for that span, so a collection inside the call updates it. Machine
// code needs none: across an evaluation its state is in a frame.
extern union field** gc_roots;
extern size_t        gc_nroots;
extern size_t        gc_roots_cap;
void gc_roots_grow(void);

static inline void gc_push_root(union field* r)
{
    if (gc_nroots == gc_roots_cap)
        gc_roots_grow();
    gc_roots[gc_nroots++] = r;
}

#define GC_ROOT(x)   gc_push_root(&(x))
#define GC_UNROOT(n) (gc_nroots -= (n))

#endif
