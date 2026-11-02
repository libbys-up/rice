#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "runtime.h"
#include "gc.h"

/* A generational, block allocated copy collector using a depth first search
 * (gc-plan.md, stage 7).
 * Block allocated, so we don't have to have an explicit to space until we run the collector.
 *
 *  * A minor collection copies only young nodes. A pointer to an old node is
 *    left alone, and old nodes aren't scanned unless they're remembered
 *    (gc_remember, gc.h). Everything it copies is promoted to the old
 *    generation. A major collection copies everything, young and old.
 *  * A node's age is the GC_OLD bit, set on every copy. A spill array's age
 *    is its header word: NULL while young, GC_OLD_ARRAY once promoted.
 *
 *  * A node is copied whole (sizeof(Node)); the original's symbol becomes
 *    gc_moved_symbol and children[0] the copy's address.
 *  * A spill array is copied when its owner is (each array has one owner;
 *    see alloc_spill in memory.h). Its header (a[-1]) records the copy's
 *    address while we collect, and its children are traced when it's
 *    copied, using its owner's layout.
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

// GC_TRAILED (gc.h) marks a node that's on the trail, so we don't elide it
// even if it's a FORWARD node (see elidable).
//
// Here's why that matters.  choose() turns a choice node C = ?(l, r) into FORWARD(l)
// and trails C.  If a parent P points at C, and we let P point straight at l,
// then when undo() restores C and the search tries r, P still points at l.

// Whether this collection is a minor one.
static bool minor;

// The remembered set: old nodes written since the last minor collection.
static Node** remembered = NULL;
static size_t remembered_n = 0;
static size_t remembered_cap = 0;

void gc_remember_slow(Node* n)
{
    if(remembered_n == remembered_cap)
    {
        remembered_cap = remembered_cap == 0 ? 1024 : remembered_cap * 2;
        remembered = (Node**)realloc(remembered, remembered_cap * sizeof(Node*));
        if(remembered == NULL)
        {
            fprintf(stderr, "Error: out of memory growing the remembered set\n");
            exit(1);
        }
    }
    n->gc_bits |= GC_REMEMBERED;
    remembered[remembered_n++] = n;
}

// The old generation's size, and when to collect it.
static size_t old_bytes = 0;
static size_t old_threshold = GC_MIN_THRESHOLD;

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
    Node* owner;       // the node it belongs to
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
static size_t     live_bytes;                  // bytes copied into the old generation (all of them, in a major collection)

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

// copy a spill array, into the old generation or the survivor space
static union field* copy_spill(union field* a, int len, Node* owner, Symbol* sym, int missing,
                               bool to_old)
{
    union field* header = a - 1;

    // old, and this is a minor collection
    if(header->a == GC_OLD_ARRAY)
    {
        if(minor)
        {
            return a;
        }
    }
    // already copied, through another owner
    else if(header->a != NULL)
    {
        return header->a;
    }

    // b holds the copy of a; b[-1] is its header
    union field* b = (union field*)gc_alloc(((size_t)len + 1) * sizeof(union field), to_old) + 1;
    memcpy(b, a, (size_t)len * sizeof(union field));
    b[-1].a = to_old ? GC_OLD_ARRAY : NULL;

    // We copied len fields + 1 header
    if(to_old)
    {
        live_bytes += ((size_t)len + 1) * sizeof(union field);
    }

    header->a = b;

    push_spill_work((SpillItem){ b, owner, sym, missing, len });
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

    // A minor collection leaves old nodes where they are.
    if(minor && (n->gc_bits & GC_OLD))
    {
        return n;
    }

    // A young node's first minor collection moves it to the survivor space;
    // its second promotes it. A major collection promotes everything.
    bool to_old = !minor || (n->gc_bits & GC_AGED);
    Node* c = (Node*)gc_alloc(sizeof(Node), to_old);
    memcpy(c, n, sizeof(Node));
    if(to_old)
    {
        c->gc_bits = (unsigned char)((c->gc_bits | GC_OLD) & ~(GC_REMEMBERED | GC_AGED));
        live_bytes += sizeof(Node);
    }
    else
    {
        c->gc_bits |= GC_AGED;
    }

    // copy spill array if we have any
    int len = gc_spill_len(n);
    if(len > 0 && n->children[3].a != NULL)
    {
        c->children[3].a = copy_spill(n->children[3].a, len, c, n->symbol, n->missing, to_old);
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

// The first trail entry a collection looks at. A minor one skips the
// clean entries (trail.h): their nodes are old, so it neither moves them nor
// elides them.
static size_t trail_from(void)
{
    return minor ? trail->clean : 0;
}

// Mark each lhs on the trail as trailed,
// so we keep any FORWARD nodes that undo() might restore.
static void mark_trailed(void)
{
    for(size_t i = trail_from(); i < trail->size; i++)
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
    for(size_t i = trail_from(); i < trail->size; i++)
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
 *  * young, in a minor collection, which never changes an old node.
 */
static bool elidable(Node* n)
{
    return !(minor && (n->gc_bits & GC_OLD)) &&
           n->missing >= 0 && 
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

// trace_child, and say whether the child is now young: still in the
// survivor space after a minor collection.
static inline bool trace_young(union field* f)
{
    trace_child(f);
    return minor && f->n != NULL && !(f->n->gc_bits & GC_OLD);
}

// After a minor collection an old node can still point at a young one: its
// child has moved to the survivor space, but isn't promoted yet. Then it
// has to be in the remembered set for the next minor collection, or that
// one wouldn't see the child.
static inline void remember_if(Node* owner, bool young_child)
{
    if(young_child)
    {
        gc_remember(owner);
    }
}

// We've copied c already, but we need to look at its children.
// For each child we come across, copy it with trace_child which will put it on
// the node stack.
static void scan_node(Node* c)
{
    bool young = false;
    // apply: 
    // child 0 is the function, 
    // then the arguments
    if(c->missing < 0)
    {
        int nargs = -c->missing;
        young |= trace_young(&c->children[0]);
        for(int i = 1; i <= nargs && i < 3; i++)
        {
            young |= trace_young(&c->children[i]);
        }
        remember_if(c, young);
        return;
    }
    Symbol* s = c->symbol;

    // special case for FORWARD or CHOICE nodes
    switch(s->tag)
    {
        case FORWARD_TAG:
            young |= trace_young(&c->children[0]);
            remember_if(c, young);
            return;
        case CHOICE_TAG:
            young |= trace_young(&c->children[0]);
            young |= trace_young(&c->children[1]);
            remember_if(c, young);
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
            young |= trace_young(&c->children[i]);
        }
    }
    remember_if(c, young);
}

static void scan_spill(SpillItem it)
{
    bool young = false;
    // an apply node's arguments: all pointers
    if(it.missing < 0) 
    {
        for(int j = 0; j < it.len; j++)
        {
            young |= trace_young(&it.a[j]);
        }
        remember_if(it.owner, young);
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
            young |= trace_young(&it.a[j]);
        }
    }
    remember_if(it.owner, young);
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

// A NULL or old node.
static bool is_old(union field f)
{
    return f.n == NULL || (f.n->gc_bits & GC_OLD);
}

// A remembered node is old and was written since the last minor collection,
// so its children may be young. Copy them, as if the node had just been.
static void scan_remembered(Node* n)
{
    n->gc_bits &= (unsigned char)~GC_REMEMBERED;
    scan_node(n);
    int len = gc_spill_len(n);
    union field* a = n->children[3].a;
    if(len > 0 && a != NULL)
    {
        // A rewrite always allocates a fresh array, so a young array is
        // copied (and scanned) like any other. An old one is scanned where
        // it is.
        if(a[-1].a != GC_OLD_ARRAY)
        {
            // The array goes where its owner is, so an old node never points
            // at a young array.
            n->children[3].a = copy_spill(a, len, n, n->symbol, n->missing, true);
        }
        else
        {
            scan_spill((SpillItem){ a, n, n->symbol, n->missing, len });
        }
    }
}

// Copy everything reachable from the roots that this collection copies:
// young nodes in a minor collection, all nodes in a major one.
static union field copy_reachable(union field root, Frame* sp)
{
    // mark every node on the trail, so we don't elide it
    mark_trailed();

    trace(&root);

    // trace each frame on the stack. A minor collection stops at the clean
    // part (machine.h), whose slots point only at old nodes.
    // Meanwhile we find where the new clean part starts: just above the
    // highest frame that still points at a young node, and never lower than
    // just above the top frame, which the program is about to write.
    union field* stop = minor ? rice_stack_hi - rice_stack_clean : rice_stack_hi;
    union field* clean_from = (union field*)sp < rice_stack_hi
                              ? (union field*)sp + 1 + sp->info->size
                              : rice_stack_hi;
    for(Frame* f = sp; (union field*)f < stop;
        f = (Frame*)((union field*)f + 1 + f->info->size))
    {
        const FrameInfo* info = f->info;
        bool young = false;
        // trace each node in the frame, if the node is actually a pointer.
        for(unsigned short i = 0; i < info->size; i++)
        {
            if(field_rep(info->reps, i) == R_PTR)
            {
                trace(&f->slots[i]);
                young |= !is_old(f->slots[i]);
            }
        }
        union field* next = (union field*)f + 1 + info->size;
        if(young && next > clean_from)
        {
            clean_from = next;
        }
    }

    // trace both lhs and rhs on the trail.
    for(size_t i = trail_from(); i < trail->size; i++)
    {
        trace(&trail->array[i].lhs);
        trace(&trail->array[i].rhs);
    }

    // trace any roots we needed.
    for(size_t i = 0; i < gc_nroots; i++)
    {
        trace(gc_roots[i]);
    }

    // In a minor collection, the old nodes that may point at young ones.
    // Scanning them can remember nodes again (remember_if), so we scan a
    // copy of the set and start a new one.
    // A major collection copies them anyway, so it just forgets them.
    size_t scanning_n = remembered_n;
    Node** scanning = NULL;
    if(minor && scanning_n > 0)
    {
        scanning = (Node**)malloc(scanning_n * sizeof(Node*));
        memcpy(scanning, remembered, scanning_n * sizeof(Node*));
    }
    remembered_n = 0;
    for(size_t i = 0; i < (minor ? scanning_n : 0); i++)
    {
        scan_remembered(scanning[i]);
    }
    free(scanning);

    // run dfs
    drain();

    // reset gc_bits on the trail nodes.
    clear_trailed();

    // Move the clean height up past the entries that are all old now.
    // After a major collection that's every entry.
    size_t clean = trail_from();
    while(clean < trail->size && is_old(trail->array[clean].lhs) && is_old(trail->array[clean].rhs))
    {
        clean++;
    }
    trail->clean = clean;
    rice_stack_clean = (size_t)(rice_stack_hi - clean_from);
    return root;
}

// Copy the nursery's survivors into the old generation.
static union field collect_minor(union field root, Frame* sp)
{
    minor = true;
    live_bytes = 0;
    heap_begin_minor();
    root = copy_reachable(root, sp);
    heap_end_minor();
    old_bytes += live_bytes;
#ifdef GC_STATS
    fprintf(stderr, "gc minor: %zu bytes promoted, old generation %zu bytes, %zu trail entries\n",
            live_bytes, old_bytes, trail->size);
#endif
    return root;
}

// Copy everything live into a new old generation.
static union field collect_major(union field root, Frame* sp)
{
    minor = false;
    live_bytes = 0;
    void* from_space = heap_begin_major();
    root = copy_reachable(root, sp);
    heap_end_major(from_space);
    old_bytes = live_bytes;
    // Collect the old generation again once it has doubled.
    // That keeps the cost of major collections proportional to how much we promote.
    old_threshold = 2 * live_bytes;
    if(old_threshold < GC_MIN_THRESHOLD)
    {
        old_threshold = GC_MIN_THRESHOLD;
    }
    debug(LOW, "gc: %zu bytes live\n", live_bytes);
#ifdef GC_STATS
    fprintf(stderr, "gc major: %zu bytes live, next at %zu, %zu trail entries\n",
            live_bytes, old_threshold, trail->size);
#endif
    return root;
}

// actually run the collector: a minor collection, then a major one if the
// old generation has grown past its threshold.
// Under GC_STRESS, every 64th collection is also a major one.
union field gc_collect(union field root, Frame* sp)
{
    // copies aren't program allocations
    unsigned long saved_mem = mem;

    root = collect_minor(root, sp);
#ifdef GC_STRESS
    static unsigned long count = 0;
    bool major = ++count % 64 == 0;
#else
    bool major = old_bytes > old_threshold;
#endif
    if(major)
    {
        root = collect_major(root, sp);
    }

    mem = saved_mem;
    rice_heap_since_gc = 0;
    return root;
}
