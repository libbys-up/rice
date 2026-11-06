#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "memory.h"
#include "gc.h"

/* The heap (docs/history/gc-plan.md, stage 7). Each space is a linked list of chunks of
 * zeroed memory with a bump allocator in its current chunk.
 *
 *  * The nursery is where the program allocates: one chunk of
 *    GC_NURSERY_BYTES, plus overflow chunks if a stretch of code between two
 *    safe points allocates more than that. It's emptied and reused after
 *    every minor collection.
 *  * Survivors are young nodes that have lived through one minor
 *    collection. The next minor collection promotes the ones still alive.
 *  * The old generation is everything promoted. Only a major collection
 *    replaces it.
 *
 * The program allocates only in the nursery (alloc, memory.h). Collections
 * copy into the survivor space or the old generation (gc_alloc).
 *
 * We use chunks rather than one big region because nodes must never move
 * except during a collection, so we can't grow a region with realloc.
 *
 * Memory has to be zeroed: fresh nodes rely on NULL children, and a spill
 * array's header has to start at 0 (see memory.h). New chunks come from
 * calloc, and the nursery is zeroed again after each minor collection.
 */

// How many allocations so far (memory.h).
unsigned long mem = 0;

// The nursery's next free byte and end.
char*  rice_alloc_next  = NULL;
char*  rice_alloc_end = NULL;

// Bytes allocated since the last collection. GC_SAFE_POINT compares this
// against rice_gc_threshold: the nursery's size, or 0 under GC_STRESS, so
// we collect at every safe point.
size_t rice_bytes_since_gc = 0;
#ifdef GC_STRESS
size_t rice_gc_threshold = 0;
#else
size_t rice_gc_threshold = GC_NURSERY_BYTES;
#endif

// The size of an ordinary chunk of the survivor space or the old
// generation, about 4MB.
// GC_STRESS uses 64KB chunks and a 64KB nursery. It collects at every safe
// point, so with 4MB chunks every collection would zero a fresh chunk and
// poison the old ones. Small chunks also take the slow path and the
// own-chunk path for big spill arrays far more often.
#ifdef GC_STRESS
#define CHUNK_BYTES   ((size_t)64 << 10)
#define NURSERY_BYTES ((size_t)64 << 10)
#else
#define CHUNK_BYTES   ((size_t)4 << 20)
#define NURSERY_BYTES GC_NURSERY_BYTES
#endif

/* A chunk's header is at its start; the usable memory follows it. */
typedef struct Chunk
{
    struct Chunk* next;
    size_t        size;  // usable bytes after the header
} Chunk;

static char* chunk_start(Chunk* c)
{
    return (char*)(c + 1);
}

static Chunk* new_chunk(size_t size)
{
    Chunk* c = (Chunk*)calloc(1, sizeof(Chunk) + size);
    if(c == NULL)
    {
        fprintf(stderr, "Error: out of memory (asking for a %zu-byte heap chunk)\n", size);
        exit(1);
    }
    c->next = NULL;
    c->size = size;
    return c;
}

// Free a list of chunks. Under GC_STRESS or a debug build, first write 0xAB
// over them: a pointer the collector failed to update then reads garbage,
// which shows up fast.
static void free_chunks(Chunk* c)
{
    while(c != NULL)
    {
        Chunk* next = c->next;
#if defined(GC_STRESS) || DEBUG > 0
        memset(chunk_start(c), 0xAB, c->size);
#endif
        free(c);
        c = next;
    }
}

// A space the collector copies into.
typedef struct
{
    Chunk* chunks;
    char*  next;
    char*  limit;
} Space;

static Space survivors;
static Space old_gen;

// survivors as they were when the current minor collection started.
static Space from_survivors;

// Bump allocate `size` bytes in `s`. A request bigger than a quarter chunk
// gets a chunk of its own, and the current chunk stays current, so one big
// spill array doesn't waste the rest of a mostly empty chunk.
static void* space_alloc(Space* s, size_t size)
{
    size = (size + 7) & ~(size_t)7;
    if((size_t)(s->limit - s->next) < size)
    {
        bool own = size > CHUNK_BYTES / 4;
        Chunk* c = new_chunk(own ? size : CHUNK_BYTES);
        c->next = s->chunks;
        s->chunks = c;
        if(own)
        {
            return chunk_start(c);
        }
        s->next  = chunk_start(c);
        s->limit = s->next + CHUNK_BYTES;
    }
    void* p = s->next;
    s->next += size;
    return p;
}

void* gc_alloc(size_t size, bool old)
{
    return space_alloc(old ? &old_gen : &survivors, size);
}

// The nursery's own chunk, and the overflow chunks allocated since the last
// minor collection.
static Chunk* nursery  = NULL;
static Chunk* overflow = NULL;

static void nursery_reset(void)
{
    rice_alloc_next  = chunk_start(nursery);
    rice_alloc_end = rice_alloc_next + NURSERY_BYTES;
}

void memory_init(void)
{
    mem = 0;
    nursery = new_chunk(NURSERY_BYTES);
    nursery_reset();
}

// alloc's slow path: the nursery (or its current overflow chunk) can't fit
// `size`, so take an overflow chunk.
void* rice_alloc_slow(size_t size)
{
    rice_bytes_since_gc += size;
    bool own = size > NURSERY_BYTES / 4;
    Chunk* c = new_chunk(own ? size : NURSERY_BYTES);
    c->next = overflow;
    overflow = c;
    if(!own)
    {
        rice_alloc_next  = chunk_start(c) + size;
        rice_alloc_end = chunk_start(c) + NURSERY_BYTES;
    }
    return chunk_start(c);
}

// How much of the nursery's own chunk was used, to zero it again.
static size_t nursery_used;

void heap_begin_minor(void)
{
    char* start = chunk_start(nursery);
    bool in_nursery = rice_alloc_next >= start && rice_alloc_next <= start + NURSERY_BYTES;
    nursery_used = in_nursery ? (size_t)(rice_alloc_next - start) : NURSERY_BYTES;
    from_survivors = survivors;
    survivors = (Space){ NULL, NULL, NULL };
}

// Everything young that's alive has been copied out: free the old survivor
// space and the overflow chunks, and empty the nursery for reuse.
void heap_end_minor(void)
{
    free_chunks(from_survivors.chunks);
    from_survivors = (Space){ NULL, NULL, NULL };
    free_chunks(overflow);
    overflow = NULL;
#if defined(GC_STRESS) || DEBUG > 0
    // A fresh nursery, so the poisoned old one catches a missed pointer.
    free_chunks(nursery);
    nursery = new_chunk(NURSERY_BYTES);
#else
    memset(chunk_start(nursery), 0, nursery_used);
#endif
    nursery_reset();
}

// A major collection copies everything into a new old generation.
// We hand back every chunk we have for heap_end_major to free.
void* heap_begin_major(void)
{
    Chunk* lists[] = { old_gen.chunks, survivors.chunks, overflow, nursery };
    Chunk* from = NULL;
    for(int i = 0; i < 4; i++)
    {
        Chunk* c = lists[i];
        while(c != NULL)
        {
            Chunk* next = c->next;
            c->next = from;
            from = c;
            c = next;
        }
    }
    old_gen = (Space){ NULL, NULL, NULL };
    survivors = (Space){ NULL, NULL, NULL };
    overflow = NULL;
    nursery = NULL;
    return from;
}

void heap_end_major(void* from)
{
    free_chunks((Chunk*)from);
    nursery = new_chunk(NURSERY_BYTES);
    nursery_reset();
}
