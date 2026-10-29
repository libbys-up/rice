#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "memory.h"
#include "gc.h"

/* We're using a bump allocator, but we're splitting memory into 4MB chunks.
 * The chunks are arranged in a linked list with a header pointing to the next chunk
 *
 *  * We're using a linked list because we need to make sure nodes don't move until
 *    the GC runs.  If we use a basic 2-space collector,
 *    we'd allocate all the memory up front and split it in half.
 *    If we needed more memory, we'd have to either ask for a completely separate heap
 *    or use realloc, which might move nodes.
 *  * 4MB is a first guess, and hasn't been tuned.
 *    It's big enough that we rarely take the slow path,
 *    and big enough that the OS hands us fresh pages that are already zeroed.
 *  * The memory has to be zeroed: fresh nodes rely on having NULL children,
 *    and a spill array's header has to start at 0 (see memory.h).
 *    That's why we use calloc.  It's required for correctness, not just speed.
 *    On macOS calloc gets fresh zeroed pages, so the zeroing is free.
 *    On Linux, after the first collection, glibc may hand back reused memory,
 *    and calloc has to clear it.  That's still correct, just slower.
 */

// Pointer to the next free heap address
char*  rice_heap_next  = NULL;

// pointer just past the last available byte in this chunk
char*  rice_heap_limit = NULL;

// number of bytes allocated since we last collected.
// GC_SAFE_POINT compares this against rice_heap_threshold.
size_t rice_heap_since_gc = 0;

// Decide when we should run the GC:
// at the next safe point after rice_heap_since_gc > rice_heap_threshold.
// It starts at GC_MIN_THRESHOLD (64MB).
// After each collection gc_collect sets it to max(GC_MIN_THRESHOLD, 2 * live bytes).
//
// GC_STRESS sets it to 0, so we collect at every safe point to stress test the GC.
#ifdef GC_STRESS
size_t rice_heap_threshold = 0;
#else
size_t rice_heap_threshold = GC_MIN_THRESHOLD;
#endif

// allocate about 4MB for each chunk.
// GC_STRESS uses 64KB chunks. It collects at every safe point, and each
// collection zeroes a fresh chunk and poisons the old ones, so with 4MB
// chunks that cost about 1ms per safe point. Small chunks also take the
// slow path and the own-chunk path for big spill arrays far more often.
#ifdef GC_STRESS
#define CHUNK_BYTES ((size_t)64 << 10)
#else
#define CHUNK_BYTES ((size_t)4 << 20)
#endif

/* Every chunk ever allocated, newest first, so the collector can find and
 * free them. The header is the first bytes of the chunk itself.
 * So the struct is written at the very start of the chunk of memory,
 * then we have a giant slab.
 * That slab isn't part of the struct here.
 */
typedef struct Chunk
{
    struct Chunk* next;
    size_t        size;  // usable bytes after the header
} Chunk;

static Chunk* chunks = NULL;

/* Allocate a new chunk of memory and put our header at the top.
 */
static char* new_chunk(size_t size)
{
    Chunk* c = (Chunk*)calloc(1, sizeof(Chunk) + size);
    
    // Out of memory, we can't do anything.
    // Maybe we can give a better error message here.
    // What does Haskell do?
    if(c == NULL)
    {
        fprintf(stderr, "Error: out of memory (asking for a %zu-byte heap chunk)\n", size);
        exit(1);
    }

    // the new chunk goes at the start of the chunk list.
    c->next = chunks;
    c->size = size;

    chunks = c;

    // c+1 move the pointer over sizeof(Chunk)
    // Then we convert to char*
    return (char*)(c + 1);
}

// We start with a single chunk.
void memory_init(void)
{
    mem = 0;
    rice_heap_next  = new_chunk(CHUNK_BYTES);
    rice_heap_limit = rice_heap_next + CHUNK_BYTES;
}

// The slow path for alloc (memory.h).
// This is only called when the current chunk doesn't have room for `size` bytes.
void* rice_alloc_slow(size_t size)
{
    rice_heap_since_gc += size;

    // A request bigger than a quarter chunk gets a chunk of its own,
    // and the current chunk stays current.
    // That way one big spill array doesn't make us throw away
    // the rest of a mostly empty chunk.
    if(size > CHUNK_BYTES / 4)
    {
        return new_chunk(size);
    }

    char* p = new_chunk(CHUNK_BYTES);
    rice_heap_next  = p + size;
    rice_heap_limit = p + CHUNK_BYTES;
    return p;
}

// Called at the start of garbage collection.
// We just start a new chunk list for to space,
// and hand back the old list (from space) so we can free it at the end.
void* heap_begin_collection(void)
{
    Chunk* old = chunks;
    chunks = NULL;
    rice_heap_next  = new_chunk(CHUNK_BYTES);
    rice_heap_limit = rice_heap_next + CHUNK_BYTES;
    return old;
}

// Called at the end of gc_collect
// This just frees all of the chunks in from space.
void heap_end_collection(void* from_space)
{
    Chunk* c = (Chunk*)from_space;
    while(c != NULL)
    {
        Chunk* next = c->next;
#if defined(GC_STRESS) || DEBUG > 0
        // Write 0xAB everywhere in the freed memory.
        // If we missed updating a pointer in gc,
        // then we'll read this and know we screwed up.
        // The memset is really slow though, so we only want to do this for debugging.
        memset(c + 1, 0xAB, c->size);
#endif
        free(c);
        c = next;
    }
}
