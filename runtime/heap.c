#include <stdio.h>
#include <stdlib.h>
#include "memory.h"

// Chunked bump allocation (src/gc-plan.md). Chunks come from calloc, so
// every allocation starts zeroed: code relies on fresh nodes having NULL
// children. Nothing is freed yet; the copying collector will free whole
// chunks.

char*  rice_heap_next  = NULL;
char*  rice_heap_limit = NULL;
size_t rice_heap_since_gc = 0;

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
