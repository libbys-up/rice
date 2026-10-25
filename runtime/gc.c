#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "runtime.h"
#include "gc.h"

/* A 2 space block allocated copy collector using a depth first search.
 * Block allocated, so we don't have to have an explicit to space until we run the collector.
 *
 *  * A node is copied whole (sizeof(Node)); the original's symbol becomes
 *    gc_moved_symbol and children[0] the copy's address.
 *  * A spill array is copied the first time any owner reaches it; its
 *    header (a[-1]) then records the copy's address, so a node and its
 *    trail snapshot that share one array still share it afterwards. The
 *    array's own children are traced once, when it's copied, using the
 *    layout of the owner that reached it first (both owners have the same
 *    symbol: an in-place rewrite always allocates a fresh array).
 *  * A node's scan traces only slots 0-2; slots 3 and up are the array's.
 *  * If we have a FORWARD chain, we can usually remove a lot of it.
 *    The FORWARD nodes must be Indistinguishable from the target (see elidable)
 *    Then we can do both path compression,
 *    but we can also set the pointer to point directly at the target.
 *    (path compression will still leave at least 1 FORWARD node).
 *    This is GHC's indirection closures.
 *    Why this is important:
 *    io1 >> io2 is going to compute io1, then reduce to FORWARD(io2).
 *    If we have a loop of IO interactions, then we'll make a long chain of forwards.
 *    These are all just artifacts of making a recursive call with side effects,
 *    so we really want to get rid of them.
 */

// The one bit we use in Node.gc_bits.
// It marks a node that's on the trail, so we don't elide it
// even if it's a FORWARD node (see elidable).
//
// Here's why that matters.  choose() turns a choice node C = ?(l, r) into FORWARD(l)
// and trails C.  If a parent P points at C, and we let P point straight at l,
// then when undo() restores C and the search tries r, P still points at l.
#define GC_TRAILED 1

// This is our marker for when a node has been moved from space -> to space
// There's exactly 1 child which is a pointer to the new node.
static Symbol gc_moved_symbol =
    { .tag = 255, .arity = 0, .name = "<gc-moved>", .hnf = &CTR_hnf };

// Defines the roots.  See gc.h
union field** gc_roots     = NULL;
size_t        gc_nroots    = 0;
size_t        gc_roots_cap = 0;

void gc_roots_grow(void)
{
    // Start with room for 64 roots, and double when we run out.
    // 64 is a guess; we rarely have more than a handful of C roots at once.
    if(gc_roots_cap == 0)
    {
        gc_roots_cap = 64;
    }
    else
    {
        gc_roots_cap = gc_roots_cap * 2;
    }
    gc_roots = (union field**)realloc(gc_roots, gc_roots_cap * sizeof(union field*));
    if(gc_roots == NULL)
    {
        fprintf(stderr, "Error: out of memory growing the GC root stack\n");
        exit(1);
    }
}

// --- work lists --------------------------------------------------------

// This struct gives us the type information we need for copying
// a spill array (since the array itself doesn't have type information)
typedef struct
{
    union field* a;    // the copied array
    Symbol* sym;       // its owner's symbol
    int missing;       // missing count so we can reconstruct representation.
    int len;           // length of the array
} SpillItem;

// These store the work stack that we're using for the dfs collector.
// We're keeping these global so that they keep their same capacity.
// The assumption here is that later collections
// are probably going to do similar amounts of work.
//
// This is dependant on the fact that we're not doing parallel work,
// and we can only collect at safe points, so we're never going to have calls to gc_collect
// clobber these variables.
static Node**     node_work = NULL;            // stack of nodes we've copied but not scanned
static size_t     node_n = 0;                  // size of node_work
static size_t     node_cap = 0;                // capacity of node_work
static SpillItem* spill_work = NULL;           // stack of spill arrays we've copied but not scanned
static size_t     spill_n = 0;                 // size of spill_work
static size_t     spill_cap = 0;               // capacity of spill_work
static size_t     live_bytes;                  // number of bytes that are still live after copying

static void push_node_work(Node* n)
{
    if(node_n == node_cap)
    {
        // start with array of 1024.
        // vector grow it as needed.
        if(node_cap == 0)
        {
            node_cap = 1024;
        }
        else
        {
            node_cap = node_cap * 2;
        }
        node_work = (Node**)realloc(node_work, node_cap * sizeof(Node*));
        if(node_work == NULL)
        {
            fprintf(stderr, "Error: out of memory growing the node work stack during GC\n");
            exit(1);
        }
    }
    node_work[node_n++] = n;
}

static void push_spill_work(SpillItem it)
{
    if(spill_n == spill_cap)
    {
        // We don't have nearly as many spill arrays, so 256 is probably a good starting place.
        if(spill_cap == 0)
        {
            spill_cap = 256;
        }
        else
        {
            spill_cap = spill_cap * 2;
        }
        spill_work = (SpillItem*)realloc(spill_work, spill_cap * sizeof(SpillItem));
        if(spill_work == NULL)
        {
            fprintf(stderr, "Error: out of memory growing the spill work stack during GC\n");
            exit(1);
        }
    }
    spill_work[spill_n++] = it;
}

// --- copying -------------------------------------------------------------

// How many children of n live in its spill array.
static int spill_len(Node* n)
{
    // Children 3 and up live in the spill array.
    // An apply node has nargs + 1 children (the function, then the arguments),
    // so nargs + 1 - 3 = nargs - 2 of them are in the spill array.
    // An ordinary node has arity children, so arity - 3 are in the spill array.
    // We compare before subtracting rather than using max(x - k, 0):
    // C has no standard integer max, and with unsigned values x - k could wrap around.
    if(n->missing < 0)
    {
        int nargs = -n->missing;
        if(nargs > 2)
        {
            return nargs - 2;
        }
        return 0;
    }
    int arity = (int)n->symbol->arity;
    if(arity > 3)
    {
        return arity - 3;
    }
    return 0;
}

// copy a spill array
static union field* copy_spill(union field* a, int len, Symbol* sym, int missing)
{
    union field* header = a - 1;

    // already copied, through another owner
    if(header->a != NULL)
    {
        return header->a;
    }

    // b holds the copy of a
    union field* b = alloc_spill((size_t)len);
    memcpy(b, a, (size_t)len * sizeof(union field));

    // We copied len fields + 1 header
    live_bytes += ((size_t)len + 1) * sizeof(union field);

    header->a = b;

    push_spill_work((SpillItem){ b, sym, missing, len });
    return b;
}

// copy a single node (not the children)
static Node* copy_node(Node* n)
{
    // We've already moved this node.
    if(n->symbol == &gc_moved_symbol)
    {
        return n->children[0].n;
    }

    // copy node into to space
    Node* c = (Node*)alloc(sizeof(Node));
    memcpy(c, n, sizeof(Node));
    live_bytes += sizeof(Node);

    // copy spill array if we have any
    int len = spill_len(n);
    if(len > 0 && n->children[3].a != NULL)
    {
        c->children[3].a = copy_spill(n->children[3].a, len, n->symbol, n->missing);
    }

    // set symbol to moved in case anyone else copies it.
    n->symbol = &gc_moved_symbol;
    n->children[0].n = c;
    push_node_work(c);
    return c;
}

// copy a node if it exists
static inline void trace(union field* f)
{
    if(f->n != NULL)
    {
        f->n = copy_node(f->n);
    }
}

// --- forwarding chains -----------------------------------------------------

// Mark each lhs on the trail as trailed,
// so we keep any FORWARD nodes that undo() might restore.
static void mark_trailed(void)
{
    for(size_t i = 0; i < trail->size; i++)
    {
        if(trail->array[i].lhs.n != NULL)
        {
            trail->array[i].lhs.n->gc_bits |= GC_TRAILED;
        }
    }
}

// clear the trailed bit at the end of garbage collection
static void clear_trailed(void)
{
    for(size_t i = 0; i < trail->size; i++)
    {
        if(trail->array[i].lhs.n != NULL)
        {
            trail->array[i].lhs.n->gc_bits &= ~GC_TRAILED;
        }
    }
}

/* Can we skip over this node, and point straight at its target?
 * Only if nobody could tell the difference.  The node must be
 *  * a FORWARD node.
 *    This also stops a chain at a node we've already moved (gc_moved_symbol's tag is 255).
 *  * deterministic.
 *    Readers OR a forward's nondet flag into their own as they pass through it,
 *    so skipping a nondet forward would lose that flag.
 *  * not on the trail (GC_TRAILED).
 *    undo() might turn it back into something else.
 *  * not an apply node, and forwarding to an actual node.
 *    Neither of these should happen (set_forward always sets missing to 0,
 *    and every caller forwards to an existing node), so these two checks are defensive.
 */
static bool elidable(Node* n)
{
    return n->missing >= 0 && 
           n->symbol->tag == FORWARD_TAG && 
           !n->nondet &&
           n->children[0].n != NULL && 
           !(n->gc_bits & GC_TRAILED);
}

// The longest FORWARD chain we're willing to walk.
// Normally a cycle of forwards can't be reached here,
// but if one ever is, this keeps the collector from hanging.
#define MAX_FORWARD_CHAIN ((size_t)1 << 20)

/* trace for a pointer stored inside a heap node.
 * This skips FORWARD nodes we don't need (see elidable), then copies the node at the end.
 *
 * Only pointers inside heap nodes do this.
 * Roots (the root argument, frame slots, C roots, and the trail) go through plain trace,
 * because their code may be about to rewrite that exact node in place.
 * If we pointed a root past the node, that code would rewrite the target instead.
 */
static inline void trace_child(union field* f)
{
    Node* n = f->n;

    // don't try to trace a NULL node
    if(n == NULL)
    {
        return;
    }

    // We found a forward node that we don't really need.
    // Let's just skip it.
    // In fact, let's skip every forward node until we reach one we have to keep.
    if(elidable(n))
    {
        Node* t = n;

        // walk the chain until we're at the end (or give up, see MAX_FORWARD_CHAIN).
        size_t steps = 0;
        while(elidable(t) && steps++ < MAX_FORWARD_CHAIN)
        {
            t = t->children[0].n;
        }

        // We hit a node that we have to copy (we didn't give up on the chain).
        // Path compression: point every node on the chain at its end, so another
        // pointer into the middle of it doesn't walk it again.
        // These are from-space nodes we haven't copied, so changing them is safe.
        if(!elidable(t))
        {
            for(Node* m = n; m != t; )
            {
                Node* next = m->children[0].n;
                m->children[0].n = t;
                m = next;
            }
            n = t;
        }
    }
    f->n = copy_node(n);
}

// --- scanning ------------------------------------------------------------

// We've copied c already, but we need to look at its children.
// For each child we come across, copy it with trace_child which will put it on
// the node stack.
static void scan_node(Node* c)
{
    // apply: 
    // child 0 is the function, 
    // then the arguments
    if(c->missing < 0)
    {
        int nargs = -c->missing;
        trace_child(&c->children[0]);
        for(int i = 1; i <= nargs && i < 3; i++)
        {
            trace_child(&c->children[i]);
        }
        return;
    }
    Symbol* s = c->symbol;

    // special case for FORWARD or CHOICE nodes
    switch(s->tag)
    {
        case FORWARD_TAG:
            trace_child(&c->children[0]);
            return;
        case CHOICE_TAG:
            trace_child(&c->children[0]);
            trace_child(&c->children[1]);
            return;
        default:
            break;
    }

    //chase all of the children that exist (we might be a partial application)
    int filled = filled_arity((union field){ .n = c });
    for(int i = 0; i < filled && i < 3; i++)
    {
        if(child_rep(s, i) == R_PTR)
        {
            trace_child(&c->children[i]);
        }
    }
}

static void scan_spill(SpillItem it)
{
    // an apply node's arguments: all pointers
    if(it.missing < 0) 
    {
        for(int j = 0; j < it.len; j++)
        {
            trace_child(&it.a[j]);
        }
        return;
    }
    // Find out how many arguments are filled (we might be a partial application).
    int filled = (int)it.sym->arity;
    if(it.missing > 0)
    {
        filled = filled - it.missing;
    }

    // copy each filled in child
    for(int j = 0; j < it.len; j++)
    {
        int i = j + 3;
        if(i < filled && child_rep(it.sym, i) == R_PTR)
        {
            trace_child(&it.a[j]);
        }
    }
}

// Walk through the stacks and copy any nodes in there
// scan_node will call copy_node on children, which may call push_node_work.
// This is what actually does the dfs on the nodes.
static void drain(void)
{
    while(node_n > 0 || spill_n > 0)
    {
        if(node_n > 0)
        {
            scan_node(node_work[--node_n]);
        }
        else
        {
            scan_spill(spill_work[--spill_n]);
        }
    }
}

// --- the collection --------------------------------------------------------

// actually run the collector
// First copy all the roots and push them on the stack
// then we call drain which runs the dfs copying.
union field gc_collect(union field root, Frame* sp)
{
    // copies aren't program allocations
    unsigned long saved_mem = mem;

    // set up garbage collection, and get from space so we can free it later.
    void* from_space = heap_begin_collection();

    live_bytes = 0;

    // mark every node on the trail, so we don't elide it
    mark_trailed();

    trace(&root);

    // trace each frame on the stack
    for(Frame* f = sp; (union field*)f < rice_stack_hi;
        f = (Frame*)((union field*)f + 1 + f->info->size))
    {
        const FrameInfo* info = f->info;
        // trace each node in the frame, if the node is actually a pointer.
        for(unsigned short i = 0; i < info->size; i++)
        {
            if(field_rep(info->reps, i) == R_PTR)
            {
                trace(&f->slots[i]);
            }
        }
    }

    // trace both lhs and rhs on the trail.
    for(size_t i = 0; i < trail->size; i++)
    {
        trace(&trail->array[i].lhs);
        trace(&trail->array[i].rhs);
    }

    // trace any roots we needed.
    for(size_t i = 0; i < gc_nroots; i++)
    {
        trace(gc_roots[i]);
    }

    // run dfs
    drain();

    // reset gc_bits on the trail nodes.
    clear_trailed();

    // reset memory tracking variables
    heap_end_collection(from_space);
    mem = saved_mem;
    rice_heap_since_gc = 0;

#ifndef GC_STRESS
    // unless we're stress testing,
    // set the heap threshold to be the max of 2 * live bytes or GC_MIN_THRESHOLD.
    // That keeps the cost of collecting proportional to how much we allocate.
    size_t want = 2 * live_bytes;
    if(want > GC_MIN_THRESHOLD)
    {
        rice_heap_threshold = want;
    }
    else
    {
        rice_heap_threshold = GC_MIN_THRESHOLD;
    }
#endif

    // print out GC stats for debugging.
    debug(LOW, "gc: %zu bytes live\n", live_bytes);
#ifdef GC_STATS
    fprintf(stderr, "gc: %zu bytes live, next at %zu allocated, %zu trail entries\n",
            live_bytes, rice_heap_threshold, trail->size);
#endif

    return root;
}
