#ifndef MEMORY_H
#define MEMORY_H

#include<stdlib.h>
#include "node.h"

/* The heap is a linked list of chunks of zeroed memory (see heap.c)
 * that contains nodes and their spill arrays.
 * Everything else (the trail, the machine stack, C strings) uses malloc.
 *
 * We never collect on allocations, only when we're at a safe point (gc.h).
 */

// How many allocations so far (nf_all prints this).
extern unsigned long mem;

extern char*  rice_heap_next;     // next free byte in the current chunk
extern char*  rice_heap_limit;    // end of the current chunk
extern size_t rice_heap_since_gc; // bytes allocated since the last collection

// Set up the heap with its first chunk.
void  memory_init(void);

// alloc's slow path: only called when the current chunk can't fit `size`.
// Don't call it directly.  It always takes a new chunk,
// so the rest of the current chunk would be wasted.
void* rice_alloc_slow(size_t size);

// For the collector: start a fresh to-space, returning the old chunk list,
// and later free that list.
void* heap_begin_collection(void);
void  heap_end_collection(void* from_space);

// Allocates `size` bytes of zeroed memory, 8-byte aligned.
// Callers rely on the memory being zeroed (NULL children, spill headers start at 0).
// If we hit the end of a chunk, then we need to take the slow path.
static inline void* alloc(size_t size)
{
    // round size up to the next multiple of 8
    size = (size + 7) & ~(size_t)7;
    mem++;
    char* p = rice_heap_next;
    if((size_t)(rice_heap_limit - p) < size)
    {
        return rice_alloc_slow(size);
    }
    rice_heap_next = p + size;
    rice_heap_since_gc += size;
    return p;
}

/* Create a node's spill array to hold all children past the 3rd one.
 * We add one header word (at a[-1]) to hold the to space address when copying.
 * It's 0 until the collector copies the array.
 *
 * A node and its trail snapshot can share one spill array:
 * save_snapshot() copies the node, not the array.
 * The header lets the collector make sure that sharing stays consistent.
 */
static inline union field* alloc_spill(size_t n)
{
    union field* a = (union field*)alloc((n + 1) * sizeof(union field));
    return a + 1;
}

#endif // MEMORY_H
