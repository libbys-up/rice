#ifndef MEMORY_H
#define MEMORY_H

#include<stdlib.h>

#ifdef GC
// Experimental Boehm build (Makefile): kept until the copying collector
// replaces it (src/gc-plan.md).
#include<gc.h>
#define memory_init() GC_INIT()
#define alloc(size) GC_MALLOC(size)
#else

// The heap: chunks of zeroed memory, bump-allocated (heap.c,
// src/gc-plan.md). Only nodes and nodes' spill arrays live here; runtime
// data structures (the trail, the evaluation stack, C strings) use malloc.
// Allocation never collects or moves anything: when a chunk is full, the
// slow path takes a fresh one. Collection happens only at safe points.

// How many allocations so far (nf_all prints this).
extern unsigned long mem;

extern char*  rice_heap_next;     // next free byte in the current chunk
extern char*  rice_heap_limit;    // end of the current chunk
extern size_t rice_heap_since_gc; // bytes allocated since the last collection

void  memory_init(void);
void* rice_alloc_slow(size_t size);

// Allocates `size` bytes of zeroed memory, 8-byte aligned.
static inline void* alloc(size_t size)
{
    size = (size + 7) & ~(size_t)7;
    mem++;
    char* p = rice_heap_next;
    if((size_t)(rice_heap_limit - p) < size)
        return rice_alloc_slow(size);
    rice_heap_next = p + size;
    rice_heap_since_gc += size;
    return p;
}

#endif

#endif
