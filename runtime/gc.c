#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "runtime.h"
#include "gc.h"

// A Cheney-style copying collector (src/gc-plan.md). Rather than scanning
// the to-space linearly (spill arrays carry no type information), it
// keeps an explicit work list of copied nodes and copied spill arrays:
//
//  * A node is copied whole (sizeof(Node)); the original's symbol becomes
//    gc_moved_symbol and children[0] the copy's address.
//  * A spill array is copied the first time any owner reaches it; its
//    header (a[-1]) then records the copy's address, so a node and its
//    trail snapshot that share one array still share it afterwards. The
//    array's own children are traced once, when it's copied, using the
//    layout of the owner that reached it first (both owners have the same
//    symbol: an in-place rewrite always allocates a fresh array).
//  * A node's scan traces only slots 0-2; slots 3 and up are the array's.

static Symbol gc_moved_symbol =
    { .tag = 255, .arity = 0, .name = "<gc-moved>", .hnf = &CTR_hnf };

union field** gc_roots     = NULL;
size_t        gc_nroots    = 0;
size_t        gc_roots_cap = 0;

void gc_roots_grow(void)
{
    gc_roots_cap = gc_roots_cap ? gc_roots_cap * 2 : 64;
    gc_roots = (union field**)realloc(gc_roots, gc_roots_cap * sizeof(union field*));
    if (gc_roots == NULL)
    {
        fprintf(stderr, "Error: out of memory growing the GC root stack\n");
        exit(1);
    }
}

// --- work lists --------------------------------------------------------

typedef struct
{
    union field* a;    // the copied array
    Symbol* sym;       // its owner's symbol and missing count, which give
    int missing;       // each element's rep
    int len;
} SpillItem;

static Node**     node_work = NULL;
static size_t     node_n = 0, node_cap = 0;
static SpillItem* spill_work = NULL;
static size_t     spill_n = 0, spill_cap = 0;
static size_t     live_bytes;

static void push_node_work(Node* n)
{
    if (node_n == node_cap)
    {
        node_cap = node_cap ? node_cap * 2 : 1024;
        node_work = (Node**)realloc(node_work, node_cap * sizeof(Node*));
    }
    node_work[node_n++] = n;
}

static void push_spill_work(SpillItem it)
{
    if (spill_n == spill_cap)
    {
        spill_cap = spill_cap ? spill_cap * 2 : 256;
        spill_work = (SpillItem*)realloc(spill_work, spill_cap * sizeof(SpillItem));
    }
    spill_work[spill_n++] = it;
}

// --- copying -------------------------------------------------------------

// How many children of n live in its spill array.
static int spill_len(Node* n)
{
    if (n->missing < 0)  // an apply node: the function, then -missing args
    {
        int nargs = -n->missing;
        return nargs >= 3 ? nargs - 2 : 0;
    }
    int arity = (int)n->symbol->arity;
    return arity > 3 ? arity - 3 : 0;
}

static union field* copy_spill(union field* a, int len, Symbol* sym, int missing)
{
    union field* header = a - 1;
    if (header->a != NULL)
        return header->a;  // already copied, through another owner
    union field* b = alloc_spill((size_t)len);
    memcpy(b, a, (size_t)len * sizeof(union field));
    live_bytes += ((size_t)len + 1) * sizeof(union field);
    header->a = b;
    push_spill_work((SpillItem){ b, sym, missing, len });
    return b;
}

static Node* copy_node(Node* n)
{
    if (n->symbol == &gc_moved_symbol)
        return n->children[0].n;
    Node* c = (Node*)alloc(sizeof(Node));
    memcpy(c, n, sizeof(Node));
    live_bytes += sizeof(Node);
    int len = spill_len(n);
    if (len > 0 && n->children[3].a != NULL)
        c->children[3].a = copy_spill(n->children[3].a, len, n->symbol, n->missing);
    n->symbol = &gc_moved_symbol;
    n->children[0].n = c;
    push_node_work(c);
    return c;
}

static inline void trace(union field* f)
{
    if (f->n != NULL)
        f->n = copy_node(f->n);
}

// --- scanning ------------------------------------------------------------

static void scan_node(Node* c)
{
    if (c->missing < 0)  // apply: child 0 the function, then the arguments
    {
        int nargs = -c->missing;
        trace(&c->children[0]);
        for (int i = 1; i <= nargs && i < 3; i++)
            trace(&c->children[i]);
        return;
    }
    Symbol* s = c->symbol;
    switch (s->tag)
    {
        case FORWARD_TAG:
            trace(&c->children[0]);
            return;
        case CHOICE_TAG:  // slot 2 is the raw side
            trace(&c->children[0]);
            trace(&c->children[1]);
            return;
        default:
            break;
    }
    int filled = filled_arity((union field){ .n = c });
    for (int i = 0; i < filled && i < 3; i++)
        if (child_rep(s, i) == R_PTR)
            trace(&c->children[i]);
}

static void scan_spill(SpillItem it)
{
    if (it.missing < 0)  // an apply node's arguments: all pointers
    {
        for (int j = 0; j < it.len; j++)
            trace(&it.a[j]);
        return;
    }
    int filled = (int)it.sym->arity - (it.missing > 0 ? it.missing : 0);
    for (int j = 0; j < it.len; j++)
    {
        int i = j + 3;
        if (i < filled && child_rep(it.sym, i) == R_PTR)
            trace(&it.a[j]);
    }
}

// --- the collection --------------------------------------------------------

union field gc_collect(union field root, Frame* sp)
{
    unsigned long saved_mem = mem;  // copies aren't program allocations
    void* from_space = heap_begin_collection();
    live_bytes = 0;

    trace(&root);

    // Frames, top to bottom of the machine stack.
    for (Frame* f = sp; (union field*)f < rice_stack_hi;
         f = (Frame*)((union field*)f + 1 + f->info->size))
    {
        const FrameInfo* info = f->info;
        for (unsigned short i = 0; i < info->size; i++)
            if (info->reps == NULL || info->reps[i] == R_PTR)
                trace(&f->slots[i]);
    }

    // The trail: each entry's node and its snapshot (or choice partner).
    for (size_t i = 0; i < bt_stack->size; i++)
    {
        trace(&bt_stack->array[i].lhs);
        trace(&bt_stack->array[i].rhs);
    }

    for (size_t i = 0; i < gc_nroots; i++)
        trace(gc_roots[i]);

    while (node_n > 0 || spill_n > 0)
    {
        if (node_n > 0)
            scan_node(node_work[--node_n]);
        else
            scan_spill(spill_work[--spill_n]);
    }

    heap_end_collection(from_space);
    mem = saved_mem;
    rice_heap_since_gc = 0;
#ifndef GC_STRESS
    size_t want = 2 * live_bytes;
    rice_heap_threshold = want > ((size_t)64 << 20) ? want : ((size_t)64 << 20);
#endif
    debug(LOW, "gc: %zu bytes live\n", live_bytes);
#ifdef GC_STATS
    fprintf(stderr, "gc: %zu bytes live, next at %zu allocated\n",
            live_bytes, rice_heap_threshold);
#endif
    return root;
}
