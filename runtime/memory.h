#ifndef MEMORY_H
#define MEMORY_H

#include<stdlib.h>
#include "node.h"

/* The heap holds nodes and their spill arrays, in chunks of zeroed memory
 * (heap.c): the nursery, where everything new goes, then the survivor
 * space and the old generation, which only the collector copies into.
 * Everything else (the trail, the machine stack, C strings) uses malloc.
 *
 * Two different limits, which are easy to confuse:
 *  * rice_alloc_next / rice_alloc_end are where alloc bumps: the nursery,
 *    or the overflow chunk it moved on to. Reaching the end takes another
 *    chunk (rice_alloc_slow). That never collects.
 *  * rice_bytes_since_gc / rice_gc_threshold (gc.h) decide when to
 *    collect. GC_SAFE_POINT collects once the bytes allocated since the
 *    last collection pass the threshold.
 * The split is because we can allocate anywhere, including C code holding
 * raw Node pointers, but we can only collect at a safe point, where every
 * live pointer is known (gc.h). So the threshold is soft: we can go past
 * it between safe points.
 */

// How many allocations so far (nf_all prints this).
extern unsigned long mem;

extern char*  rice_alloc_next;     // next free byte where alloc bumps
extern char*  rice_alloc_end;      // the end of that space
extern size_t rice_bytes_since_gc; // bytes allocated since the last collection

// Set up the heap with its first chunk.
void  memory_init(void);

// alloc's slow path: only called when the space alloc bumps through can't
// fit `size`. Don't call it directly.  It always takes a new chunk,
// so the rest of the current one would be wasted.
void* rice_alloc_slow(size_t size);

// For the collector (gc.c). It copies with gc_alloc, into the survivor
// space or the old generation, never with alloc.
// A minor collection copies the young nodes that are alive; end frees the
// previous survivor space and empties the nursery. A major one copies
// everything; begin hands back every chunk for end to free.
void* gc_alloc(size_t size, bool old);
void  heap_begin_minor(void);
void  heap_end_minor(void);
void* heap_begin_major(void);
void  heap_end_major(void* from_space);

// Allocates `size` bytes of zeroed memory, 8-byte aligned.
// Callers rely on the memory being zeroed (NULL children, spill headers start at 0).
// If we hit the end of the space, then we need to take the slow path.
static inline void* alloc(size_t size)
{
    // round size up to the next multiple of 8
    size = (size + 7) & ~(size_t)7;
    mem++;
    char* p = rice_alloc_next;
    if((size_t)(rice_alloc_end - p) < size)
    {
        return rice_alloc_slow(size);
    }
    rice_alloc_next = p + size;
    rice_bytes_since_gc += size;
    return p;
}

/* Create a node's spill array to hold all children past the 3rd one.
 * We add one header word (at a[-1]): the collector keeps the array's age
 * there, and the address of its copy while it collects (gc.h).
 *
 * Every array has one owner. A trail snapshot gets its own copy of the
 * node's array (save_snapshot), because the write barrier works per node:
 * an array shared with a snapshot could keep pointers to young nodes after
 * the node itself had moved on to a fresh array.
 */
static inline union field* alloc_spill(size_t n)
{
    union field* a = (union field*)alloc((n + 1) * sizeof(union field));
    return a + 1;
}

#endif // MEMORY_H
