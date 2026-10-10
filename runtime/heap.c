#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "memory.h"

// Chunked bump allocation (src/gc-plan.md). Chunks come from calloc, so
// every allocation starts zeroed: code relies on fresh nodes having NULL
// children. The collector (gc.c) copies everything live into fresh chunks
// and frees the old ones whole.

char*  rice_heap_next  = NULL;
char*  rice_heap_limit = NULL;
size_t rice_heap_since_gc = 0;
#ifdef GC_STRESS
size_t rice_heap_threshold = 0;
#else
size_t rice_heap_threshold = (size_t)64 << 20;
#endif

#define CHUNK_BYTES ((size_t)4 << 20)

// Every chunk ever allocated, newest first, so the collector can find and
// free them. The header is the first bytes of the chunk itself.
typedef struct Chunk
{
    struct Chunk* next;
    size_t        size;  // usable bytes after the header
} Chunk;

static Chunk* chunks = NULL;

static char* new_chunk(size_t size)
{
    Chunk* c = (Chunk*)calloc(1, sizeof(Chunk) + size);
    if(c == NULL)
    {
        fprintf(stderr, "Error: out of memory (asking for a %zu-byte heap chunk)\n", size);
        exit(1);
    }
    c->next = chunks;
    c->size = size;
    chunks = c;
    return (char*)(c + 1);
}

void memory_init(void)
{
    mem = 0;
    rice_heap_next  = new_chunk(CHUNK_BYTES);
    rice_heap_limit = rice_heap_next + CHUNK_BYTES;
}

void* rice_alloc_slow(size_t size)
{
    rice_heap_since_gc += size;
    // A request bigger than a chunk gets a chunk of its own, and the
    // current chunk stays current.
    if(size > CHUNK_BYTES / 4)
        return new_chunk(size);
    char* p = new_chunk(CHUNK_BYTES);
    rice_heap_next  = p + size;
    rice_heap_limit = p + CHUNK_BYTES;
    return p;
}

void* heap_begin_collection(void)
{
    Chunk* old = chunks;
    chunks = NULL;
    rice_heap_next  = new_chunk(CHUNK_BYTES);
    rice_heap_limit = rice_heap_next + CHUNK_BYTES;
    return old;
}

void heap_end_collection(void* from_space)
{
    Chunk* c = (Chunk*)from_space;
    while (c != NULL)
    {
        Chunk* next = c->next;
#if defined(GC_STRESS) || DEBUG > 0
        // A stale pointer into freed space then reads this pattern, which
        // tag dispatch and CHECK_LAYOUT reject, instead of old data that
        // happens to still look right.
        memset(c + 1, 0xAB, c->size);
#endif
        free(c);
        c = next;
    }
}
