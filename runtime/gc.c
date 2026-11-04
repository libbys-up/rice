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
// A major collection also runs when the trail has doubled since the last
// one, since only a major collection drops dead trail entries
// (compact_trail, trail_liveness), and until then they keep what they point
// at alive through every minor collection.
static size_t trail_threshold = GC_MIN_TRAIL;

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

// The state of one collection: the work stacks for the depth-first copy,
// and how much we copied. It's only meaningful during gc_collect.
// It's one global so the arrays keep their capacity from one collection to
// the next; later collections probably do similar amounts of work.
//
// That's safe because collection is single-threaded, and only happens at
// safe points, never inside itself (alloc never collects).
static struct
{
    Node**     nodes;       // nodes we've copied but not scanned
    size_t     node_n;      // how many are in nodes
    size_t     node_cap;    // capacity of nodes
    SpillItem* spills;      // spill arrays we've copied but not scanned
    size_t     spill_n;     // how many are in spills
    size_t     spill_cap;   // capacity of spills
    size_t     live_bytes;  // bytes copied into the old generation (all of them, in a major collection)
} work = { NULL, 0, 0, NULL, 0, 0, 0 };

static void push_node_work(Node* n)
{
    if(work.node_n == work.node_cap)
    {
        // start with array of 1024.
        // vector grow it as needed.
        if(work.node_cap == 0)
        {
            work.node_cap = 1024;
        }
        else
        {
            work.node_cap = work.node_cap * 2;
        }
        work.nodes = (Node**)realloc(work.nodes, work.node_cap * sizeof(Node*));
        if(work.nodes == NULL)
        {
            fprintf(stderr, "Error: out of memory growing the node work stack during GC\n");
            exit(1);
        }
    }
    work.nodes[work.node_n++] = n;
}

static void push_spill_work(SpillItem it)
{
    if(work.spill_n == work.spill_cap)
    {
        // We don't have nearly as many spill arrays, so 256 is probably a good starting place.
        if(work.spill_cap == 0)
        {
            work.spill_cap = 256;
        }
        else
        {
            work.spill_cap = work.spill_cap * 2;
        }
        work.spills = (SpillItem*)realloc(work.spills, work.spill_cap * sizeof(SpillItem));
        if(work.spills == NULL)
        {
            fprintf(stderr, "Error: out of memory growing the spill work stack during GC\n");
            exit(1);
        }
    }
    work.spills[work.spill_n++] = it;
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
        work.live_bytes += ((size_t)len + 1) * sizeof(union field);
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
        // GC_VISITED, GC_SEEN: trail_liveness marks from-space nodes, and
        // copying them is how they're cleared.
        c->gc_bits = (unsigned char)((c->gc_bits | GC_OLD) &
                                     ~(GC_REMEMBERED | GC_AGED | GC_VISITED | GC_SEEN));
        work.live_bytes += sizeof(Node);
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
    while(work.node_n > 0 || work.spill_n > 0)
    {
        if(work.node_n > 0)
        {
            scan_node(work.nodes[--work.node_n]);
        }
        else
        {
            scan_spill(work.spills[--work.spill_n]);
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

// --- GC_VERIFY ---------------------------------------------------------------

#ifdef GC_VERIFY
/* Checks what a minor collection relies on, over everything reachable:
 *  * an old node that points at a young node, or has a young spill array,
 *    is remembered (the write barrier did its job);
 *  * the trail's clean entries and the stack's clean frames point only at
 *    old nodes (the watermarks are right).
 * It walks the whole heap, so it's only for debugging. A violation stops
 * the program, naming the node.
 */
// A growable list of nodes.
typedef struct
{
    Node** a;
    size_t n;
    size_t cap;
} NodeList;

static NodeList verify_work;  // visited, not yet checked
static NodeList verify_seen;  // visited, so GC_VISITED can be cleared

static void push(NodeList* l, Node* x)
{
    if(l->n == l->cap)
    {
        l->cap = l->cap == 0 ? 4096 : l->cap * 2;
        l->a = (Node**)realloc(l->a, l->cap * sizeof(Node*));
    }
    l->a[l->n++] = x;
}

static void verify_visit(Node* n)
{
    if(n == NULL || (n->gc_bits & GC_VISITED))
    {
        return;
    }
    n->gc_bits |= GC_VISITED;
    push(&verify_seen, n);
    push(&verify_work, n);
}

static void verify_fail(const char* what, Node* n, const char* when)
{
    fprintf(stderr, "GC_VERIFY (%s a minor collection): %s: %s", when, what,
            n->symbol != NULL ? n->symbol->name : "<no symbol>");
    fprintf(stderr, " at %p\n", (void*)n);
    abort();
}

// Is this pointer to a young node?
static bool young_ptr(union field f)
{
    return f.n != NULL && !(f.n->gc_bits & GC_OLD);
}

// Visit n's pointer children, and check the barrier invariant for it.
static void verify_node(Node* n, const char* when)
{
    bool old = n->gc_bits & GC_OLD;
    bool covered = !old || (n->gc_bits & GC_REMEMBERED);
    int ptrs = 0;              // children 0..ptrs-1 might be pointers
    bool all_ptrs = false;     // every one of them is (apply, FORWARD, CHOICE)
    if(n->missing < 0)
    {
        ptrs = -n->missing + 1;
        all_ptrs = true;
    }
    else if(n->symbol->tag == FORWARD_TAG)
    {
        ptrs = 1;
        all_ptrs = true;
    }
    else if(n->symbol->tag == CHOICE_TAG)
    {
        ptrs = 2;
        all_ptrs = true;
    }
    else
    {
        ptrs = filled_arity((union field){ .n = n });
    }
    int len = gc_spill_len(n);
    union field* a = n->children[3].a;
    if(old && !covered && len > 0 && a != NULL && a[-1].a != GC_OLD_ARRAY)
    {
        verify_fail("old node not remembered, with a young spill array", n, when);
    }
    for(int i = 0; i < ptrs; i++)
    {
        if(!all_ptrs && child_rep(n->symbol, i) != R_PTR)
        {
            continue;
        }
        if(i >= 3 && (len == 0 || a == NULL))
        {
            break;
        }
        union field c = i < 3 ? n->children[i] : a[i - 3];
        if(old && !covered && young_ptr(c))
        {
            verify_fail("old node not remembered, pointing at a young one", n, when);
        }
        verify_visit(c.n);
    }
}

static void gc_verify(union field root, Frame* sp, const char* when)
{
    verify_work.n = 0;
    verify_seen.n = 0;
    verify_visit(root.n);
    union field* stop = rice_stack_hi - rice_stack_clean;
    for(Frame* f = sp; (union field*)f < rice_stack_hi;
        f = (Frame*)((union field*)f + 1 + f->info->size))
    {
        for(unsigned short i = 0; i < f->info->size; i++)
        {
            if(field_rep(f->info->reps, i) != R_PTR)
            {
                continue;
            }
            if((union field*)f >= stop && young_ptr(f->slots[i]))
            {
                fprintf(stderr, "GC_VERIFY (%s a minor collection): clean frame %s points at a young node\n",
                        when, f->info->name);
                abort();
            }
            verify_visit(f->slots[i].n);
        }
    }
    for(size_t i = 0; i < trail->size; i++)
    {
        TrailEntry* e = &trail->array[i];
        if(i < trail->clean && (young_ptr(e->lhs) || young_ptr(e->rhs)))
        {
            fprintf(stderr, "GC_VERIFY (%s a minor collection): clean trail entry %zu points at a young node\n",
                    when, i);
            abort();
        }
        verify_visit(e->lhs.n);
        verify_visit(e->rhs.n);
    }
    for(size_t i = 0; i < gc_nroots; i++)
    {
        verify_visit(gc_roots[i]->n);
    }
    for(size_t i = 0; i < remembered_n; i++)
    {
        verify_visit(remembered[i]);
    }
    while(verify_work.n > 0)
    {
        verify_node(verify_work.a[--verify_work.n], when);
    }
    for(size_t i = 0; i < verify_seen.n; i++)
    {
        verify_seen.a[i]->gc_bits &= (unsigned char)~GC_VISITED;
    }
}
#endif

// Copy the nursery's survivors into the old generation.
static union field collect_minor(union field root, Frame* sp)
{
#ifdef GC_VERIFY
    gc_verify(root, sp, "before");
#endif
    minor = true;
    work.live_bytes = 0;
    heap_begin_minor();
    root = copy_reachable(root, sp);
    heap_end_minor();
#ifdef GC_VERIFY
    gc_verify(root, sp, "after");
#endif
    old_bytes += work.live_bytes;
#ifdef GC_STATS
    fprintf(stderr, "gc minor: %zu bytes promoted, old generation %zu bytes, %zu trail entries\n",
            work.live_bytes, old_bytes, trail->size);
#endif
    return root;
}

// --- trail compaction (LEAKS.md, leak 2) -----------------------------------

#ifndef GC_NO_TRAIL_COMPACT
/* A stop height is a trail size at which an undo or pop_to can end: the
 * index of each choice entry (undo pops it, then stops), and every height
 * the program holds (R_TRAIL and R_CUTOFF frame slots), plus 0 and the
 * top. A segment is the stretch between two neighboring stop heights.
 * Every undo and pop_to handles whole segments, and nothing reads the heap
 * partway through one (LEAKS.md, S1-S3).
 *
 * D1: within a segment, only a node's lowest entry matters. undo restores
 * the higher ones first, and the lowest one overwrites them, so we drop
 * them. A segment's bottom entry is always some node's lowest, so the
 * epoch undo and pop_to read from it stays.
 *
 * Then the trail is compacted, and every height the program holds becomes
 * the number of entries kept below it.
 */
static size_t* stop = NULL;
static size_t  stop_n = 0, stop_cap = 0;
static size_t* kept_below = NULL;  // kept_below[h]: entries kept below height h
static size_t  kept_cap = 0;

static void add_stop(size_t h)
{
    if(stop_n == stop_cap)
    {
        stop_cap = stop_cap == 0 ? 256 : stop_cap * 2;
        stop = (size_t*)realloc(stop, stop_cap * sizeof(size_t));
    }
    stop[stop_n++] = h;
}

static int compare_size(const void* a, const void* b)
{
    size_t x = *(const size_t*)a, y = *(const size_t*)b;
    return x < y ? -1 : x > y;
}

// The height h held by the program, after compaction. A height above the
// top (the trail was popped below it) keeps its distance from the top.
static size_t new_height(size_t h, size_t old_size)
{
    if(h > old_size)
    {
        return kept_below[old_size] + (h - old_size);
    }
    return kept_below[h];
}

// Apply f to every height slot in the frames.
static void remap_frame_heights(Frame* sp, size_t old_size)
{
    for(Frame* f = sp; (union field*)f < rice_stack_hi;
        f = (Frame*)((union field*)f + 1 + f->info->size))
    {
        for(unsigned short i = 0; i < f->info->size; i++)
        {
            FieldRep r = field_rep(f->info->reps, i);
            if(r == R_TRAIL)
            {
                f->slots[i].i = (long)new_height((size_t)f->slots[i].i, old_size);
            }
            else if(r == R_CUTOFF && f->slots[i].i > 0)
            {
                f->slots[i].i = (long)new_height((size_t)f->slots[i].i - 1, old_size) + 1;
            }
        }
    }
}

static void compact_trail(Frame* sp)
{
    size_t size = trail->size;
    if(size == 0)
    {
        return;
    }

    // The stop heights, sorted, without duplicates.
    stop_n = 0;
    add_stop(0);
    add_stop(size);
    for(size_t i = 0; i < size; i++)
    {
        if(trail->array[i].choice)
        {
            add_stop(i);
        }
    }
    for(Frame* f = sp; (union field*)f < rice_stack_hi;
        f = (Frame*)((union field*)f + 1 + f->info->size))
    {
        for(unsigned short i = 0; i < f->info->size; i++)
        {
            FieldRep r = field_rep(f->info->reps, i);
            if(r == R_TRAIL)
            {
                add_stop((size_t)f->slots[i].i);
            }
            else if(r == R_CUTOFF && f->slots[i].i > 0)
            {
                add_stop((size_t)f->slots[i].i - 1);
            }
        }
    }
    qsort(stop, stop_n, sizeof(size_t), compare_size);

    if(kept_cap < size + 1)
    {
        kept_cap = size + 1;
        kept_below = (size_t*)realloc(kept_below, kept_cap * sizeof(size_t));
    }

    // D1, segment by segment, keeping entries in place as we go.
    size_t kept = 0;
    size_t s = 0;  // the next stop height above the current segment
    size_t seg_start = 0;
    for(size_t i = 0; i < size; i++)
    {
        // Entering a new segment: forget the last one's nodes.
        while(s < stop_n && stop[s] <= i)
        {
            if(stop[s] == i && i > seg_start)
            {
                for(size_t j = kept_below[seg_start]; j < kept; j++)
                {
                    Node* l = trail->array[j].lhs.n;
                    if(l != NULL)
                    {
                        l->gc_bits &= (unsigned char)~GC_SEEN;
                    }
                }
                seg_start = i;
            }
            s++;
        }
        kept_below[i] = kept;
        TrailEntry e = trail->array[i];
        Node* l = e.lhs.n;
        if(l != NULL && !e.choice && (l->gc_bits & GC_SEEN))
        {
            continue;  // a lower entry in this segment restores this node
        }
        if(l != NULL)
        {
            l->gc_bits |= GC_SEEN;
        }
        trail->array[kept++] = e;
    }
    kept_below[size] = kept;
    for(size_t j = kept_below[seg_start]; j < kept; j++)
    {
        Node* l = trail->array[j].lhs.n;
        if(l != NULL)
        {
            l->gc_bits &= (unsigned char)~GC_SEEN;
        }
    }

    remap_frame_heights(sp, size);
    trail->size = kept;
    if(trail->clean > kept)
    {
        trail->clean = kept;
    }

    // Leave the stop heights in the new coordinates, for trail_liveness.
    // Heights above the top aren't segment boundaries; drop them.
    size_t n = 0;
    for(size_t k = 0; k < stop_n; k++)
    {
        if(stop[k] <= size)
        {
            size_t h = kept_below[stop[k]];
            if(n == 0 || stop[n - 1] != h)
            {
                stop[n++] = h;
            }
        }
    }
    stop_n = n;
#ifdef GC_STATS
    fprintf(stderr, "gc trail: %zu entries, %zu kept, %zu stop heights\n", size, kept, stop_n);
#endif
}

#ifndef GC_NO_TRAIL_LIVENESS
/* D2-D4: which versions of a trailed node can still be read (LEAKS.md,
 * "Proposed fix"). This runs after compact_trail, before the copy, and
 * looks only at from-space.
 *
 * A view is a stop height h: the heap after undo has brought the trail
 * down to h. View size is the heap now. After D1 a node L has at most one
 * entry per segment, so its versions split the views between them:
 *  * its current contents, in views [b, size], where b is the top of the
 *    segment holding L's highest entry;
 *  * the snapshot (rhs) of entry i, in segment [a, b), in views [b', a],
 *    where b' is the top of the segment holding L's next entry below i
 *    (0 if there isn't one).
 *
 * We trace versions, each with its views. The roots reach every version of
 * the nodes they point at, except that a frame is only read in some views
 * (frame_views). A version reaches, for each child, every version
 * of that child whose views meet its own. An untrailed node has one version
 * in every view, but which views it's reached from still matters: the
 * versions its children reach depend on them. So it's scanned from the
 * smallest range of views that holds every one it's been reached from,
 * and scanned again when that range grows. Reached from every view, it's
 * GC_VISITED and GC_SEEN, which is ordinary data's case, and just a mark
 * phase. Reached from fewer, it's GC_VISITED alone, and its range is in
 * the partial table. After MAX_WIDENINGS rescans we stop being precise and
 * scan it from every view.
 *
 * pop_to(n) discards segments instead of undoing them, so after a commit
 * the views below n can see versions that, by the views above, are only
 * visible at n or higher. So a version visible at the lowest commit height
 * (an R_TRAIL slot, counted conservatively) also counts as visible down to
 * the top of L's highest entry below that height.
 *
 * Then
 *  * D2: an entry whose version wasn't reached is dropped.
 *  * D3: a node whose current version wasn't reached, but which has a live
 *    entry, has to survive, since undo writes into it. Its current
 *    contents don't, so they become gc_dead_symbol, which stops the
 *    program if anything ever does read it.
 *  * D4: a dead entry at the bottom of its segment (every choice entry is
 *    one) stays as an empty entry (lhs NULL), since undo and pop_to read
 *    the epoch there, and undo stops at a choice entry.
 * and the trail is compacted again, as in compact_trail.
 *
 * Every rhs is a fresh node that only its entry points at (save_snapshot,
 * choose, push_node's copy, the free variables of push_frame and
 * push_choice), so a version's contents are its rhs's children. If an rhs
 * were ever trailed itself, its contents would depend on the view, so we
 * give up and keep the whole trail.
 */
static RICE_CC void gc_dead_hnf(union field _root, Frame* sp)
{
    (void)_root;
    (void)sp;
    fprintf(stderr, "Error: the program read a node that the garbage collector "
                    "found unreachable (gc.c, trail_liveness)\n");
    exit(3);
}

static Symbol gc_dead_symbol =
    { .tag = FUNCTION_TAG, .arity = 0, .name = "<gc-dead>", .hnf = &gc_dead_hnf };

#define NO_ENTRY ((size_t)-1)

// The versions of one trailed node.
typedef struct
{
    Node*  node;
    size_t top;        // its highest entry
    size_t b_below;    // the top of the segment of its highest entry below commit_min, or 0
    size_t versions;   // entries + 1 (current)
    size_t unreached;  // versions not reached yet
    bool   current;    // its current version is reached
} Versions;

typedef struct
{
    Node*  n;          // scan this node's children
    size_t lo, hi;     // as seen from these views
} LiveItem;

static size_t*   seg_a = NULL;     // seg_a[i], seg_b[i]: entry i's segment [a, b)
static size_t*   seg_b = NULL;
static size_t*   lower = NULL;     // lower[i]: the same node's next entry below i
static bool*     reached = NULL;   // reached[i]: entry i's version is reached
static size_t    entries_cap = 0;
static Versions* recs = NULL;
static size_t    recs_n = 0;
static size_t*   table = NULL;     // open addressing, node -> 1 + index into recs, 0 = empty
static size_t    table_cap = 0;
static LiveItem* live_work = NULL;
static size_t    live_n = 0, live_cap = 0;
static size_t    view_top;         // the trail's size: the current view

// The range of views an untrailed node has been reached from, when that
// isn't all of them.
typedef struct
{
    Node*    n;
    size_t   lo, hi;
    unsigned widenings;
} Partial;

#define MAX_WIDENINGS 4

static Partial*  partial = NULL;   // open addressing, n == NULL is empty
static size_t    partial_n = 0, partial_cap = 0;
static size_t    commit_min;       // the lowest commit height, or NO_ENTRY

static void* grow(void* p, size_t n, size_t each)
{
    p = realloc(p, n * each);
    if(p == NULL)
    {
        fprintf(stderr, "Error: out of memory in the trail liveness pass\n");
        exit(1);
    }
    return p;
}

static size_t hash_ptr(Node* n, size_t cap)
{
    return (size_t)(((uintptr_t)n >> 4) * 0x9E3779B97F4A7C15ull) & (cap - 1);
}

static size_t hash_node(Node* n)
{
    return hash_ptr(n, table_cap);
}

static Partial* find_partial(Node* n)
{
    size_t h = hash_ptr(n, partial_cap);
    while(partial[h].n != NULL && partial[h].n != n)
    {
        h = (h + 1) & (partial_cap - 1);
    }
    return &partial[h];
}

// Room for one more node in the partial table, keeping it at most half full.
static void partial_reserve(void)
{
    if(2 * (partial_n + 1) <= partial_cap)
    {
        return;
    }
    Partial* old = partial;
    size_t old_cap = partial_cap;
    partial_cap = partial_cap == 0 ? 1024 : partial_cap * 2;
    partial = (Partial*)calloc(partial_cap, sizeof(Partial));
    if(partial == NULL)
    {
        fprintf(stderr, "Error: out of memory in the trail liveness pass\n");
        exit(1);
    }
    for(size_t i = 0; i < old_cap; i++)
    {
        if(old[i].n != NULL)
        {
            *find_partial(old[i].n) = old[i];
        }
    }
    free(old);
}

static Versions* find_versions(Node* n, bool add)
{
    size_t h = hash_node(n);
    while(table[h] != 0)
    {
        if(recs[table[h] - 1].node == n)
        {
            return &recs[table[h] - 1];
        }
        h = (h + 1) & (table_cap - 1);
    }
    if(!add)
    {
        return NULL;
    }
    recs[recs_n] = (Versions){ n, NO_ENTRY, 0, 1, 1, false };
    table[h] = ++recs_n;
    return &recs[recs_n - 1];
}

// The commit widening (above): a version visible at the lowest commit
// height is visible down to b_below.
static void widen(const Versions* v, size_t* lo, size_t hi)
{
    if(hi >= commit_min && v->b_below < *lo)
    {
        *lo = v->b_below;
    }
}

static void current_views(const Versions* v, size_t* lo, size_t* hi)
{
    *lo = seg_b[v->top];
    *hi = view_top;
    widen(v, lo, *hi);
}

static void entry_views(const Versions* v, size_t i, size_t* lo, size_t* hi)
{
    *lo = lower[i] == NO_ENTRY ? 0 : seg_b[lower[i]];
    *hi = seg_a[i];
    widen(v, lo, *hi);
}

static void push_live(Node* n, size_t lo, size_t hi)
{
    if(n == NULL)
    {
        return;
    }
    if(live_n == live_cap)
    {
        live_cap = live_cap == 0 ? 1024 : live_cap * 2;
        live_work = (LiveItem*)grow(live_work, live_cap, sizeof(LiveItem));
    }
    live_work[live_n++] = (LiveItem){ n, lo, hi };
}

// n is reached from views [lo, hi].
static void live_reach(Node* n, size_t lo, size_t hi)
{
    if(n == NULL)
    {
        return;
    }
    if(!(n->gc_bits & GC_TRAILED))
    {
        if(n->gc_bits & GC_SEEN)
        {
            return;  // already scanned from every view
        }
        bool all = lo == 0 && hi == view_top;
        if(!(n->gc_bits & GC_VISITED))
        {
            n->gc_bits |= GC_VISITED;
            if(all)
            {
                n->gc_bits |= GC_SEEN;
            }
            else
            {
                partial_reserve();
                *find_partial(n) = (Partial){ n, lo, hi, 0 };
                partial_n++;
            }
            push_live(n, lo, hi);
            return;
        }
        Partial* p = find_partial(n);
        if(lo >= p->lo && hi <= p->hi)
        {
            return;
        }
        p->lo = lo < p->lo ? lo : p->lo;
        p->hi = hi > p->hi ? hi : p->hi;
        if(++p->widenings > MAX_WIDENINGS || (p->lo == 0 && p->hi == view_top))
        {
            n->gc_bits |= GC_SEEN;
            push_live(n, 0, view_top);
        }
        else
        {
            push_live(n, p->lo, p->hi);
        }
        return;
    }
    Versions* v = find_versions(n, false);
    if(v->unreached == 0)
    {
        return;
    }
    size_t vlo, vhi;
    if(!v->current)
    {
        current_views(v, &vlo, &vhi);
        if(vlo <= hi && lo <= vhi)
        {
            v->current = true;
            v->unreached--;
            push_live(n, vlo, vhi);
        }
    }
    // Going down, the versions' highest views only go down.
    for(size_t i = v->top; i != NO_ENTRY; i = lower[i])
    {
        entry_views(v, i, &vlo, &vhi);
        if(vhi < lo)
        {
            break;
        }
        if(!reached[i] && vlo <= hi)
        {
            reached[i] = true;
            v->unreached--;
            push_live(trail->array[i].rhs.n, vlo, vhi);
        }
    }
}

// Reach each of n's children from views [lo, hi]. This follows the same
// children as scan_node and scan_spill.
static void live_scan(Node* n, size_t lo, size_t hi)
{
    union field* a = n->children[3].a;
    int len = gc_spill_len(n);
    if(n->missing < 0)
    {
        int nargs = -n->missing;
        live_reach(n->children[0].n, lo, hi);
        for(int i = 1; i <= nargs && i < 3; i++)
        {
            live_reach(n->children[i].n, lo, hi);
        }
        for(int j = 0; j < len && a != NULL; j++)
        {
            live_reach(a[j].n, lo, hi);
        }
        return;
    }
    Symbol* s = n->symbol;
    switch(s->tag)
    {
        case FORWARD_TAG:
            live_reach(n->children[0].n, lo, hi);
            return;
        case CHOICE_TAG:
            live_reach(n->children[0].n, lo, hi);
            live_reach(n->children[1].n, lo, hi);
            return;
        default:
            break;
    }
    int filled = filled_arity((union field){ .n = n });
    for(int i = 0; i < filled && i < 3; i++)
    {
        if(child_rep(s, i) == R_PTR)
        {
            live_reach(n->children[i].n, lo, hi);
        }
    }
    for(int j = 0; j < len && a != NULL; j++)
    {
        if(j + 3 < filled && child_rep(s, j + 3) == R_PTR)
        {
            live_reach(a[j].n, lo, hi);
        }
    }
}

/* The lowest view frame f's slots can be read in, given lo, the lowest
 * for the frame above it.
 * Every undo is run by a frame, to a cutoff it holds: a scoped retry's
 * R_CUTOFF slot, lazy unification's R_TRAIL slot. (nf_all's undo(0) is
 * outside the machine; what it reads is a C root, which we reach from every
 * view.) By the time a frame runs its undo, every frame above it has been
 * popped. So f is only read in the views that it, or a frame above it,
 * can undo to. A cutoff not marked yet (0) will be the trail's size when
 * it's marked, which is never lower than what the frames above can undo
 * to. A bindIO commit height is counted too, conservatively.
 */
static size_t frame_views(Frame* f, size_t lo)
{
    for(unsigned short i = 0; i < f->info->size; i++)
    {
        FieldRep r = field_rep(f->info->reps, i);
        size_t h = (size_t)f->slots[i].i;
        if(r == R_TRAIL && h < lo)
        {
            lo = h;
        }
        else if(r == R_CUTOFF && h > 0 && h - 1 < lo)
        {
            lo = h - 1;
        }
    }
    return lo;
}

static void clear_trailed_all(size_t size)
{
    for(size_t i = 0; i < size; i++)
    {
        if(trail->array[i].lhs.n != NULL)
        {
            trail->array[i].lhs.n->gc_bits &= (unsigned char)~GC_TRAILED;
        }
    }
}

static void trail_liveness(union field root, Frame* sp)
{
    size_t size = trail->size;
    if(size == 0)
    {
        return;
    }
    view_top = size;
    if(entries_cap < size)
    {
        entries_cap = size;
        seg_a = (size_t*)grow(seg_a, size, sizeof(size_t));
        seg_b = (size_t*)grow(seg_b, size, sizeof(size_t));
        lower = (size_t*)grow(lower, size, sizeof(size_t));
        reached = (bool*)grow(reached, size, sizeof(bool));
        recs = (Versions*)grow(recs, size, sizeof(Versions));
    }
    size_t want = 16;
    while(want < 2 * size)
    {
        want *= 2;
    }
    if(table_cap < want)
    {
        table_cap = want;
        table = (size_t*)grow(table, table_cap, sizeof(size_t));
    }
    memset(table, 0, table_cap * sizeof(size_t));
    recs_n = 0;

    // Each entry's segment. stop holds 0 and size, sorted (compact_trail).
    size_t s = 0;
    for(size_t i = 0; i < size; i++)
    {
        while(s + 1 < stop_n && stop[s + 1] <= i)
        {
            s++;
        }
        seg_a[i] = stop[s];
        seg_b[i] = stop[s + 1];
    }

    // The lowest commit height.
    commit_min = NO_ENTRY;
    for(Frame* f = sp; (union field*)f < rice_stack_hi;
        f = (Frame*)((union field*)f + 1 + f->info->size))
    {
        for(unsigned short i = 0; i < f->info->size; i++)
        {
            if(field_rep(f->info->reps, i) == R_TRAIL && (size_t)f->slots[i].i < commit_min)
            {
                commit_min = (size_t)f->slots[i].i;
            }
        }
    }

    // Every node's versions.
    for(size_t i = 0; i < size; i++)
    {
        if(trail->array[i].lhs.n != NULL)
        {
            trail->array[i].lhs.n->gc_bits |= GC_TRAILED;
        }
    }
    for(size_t i = 0; i < size; i++)
    {
        reached[i] = false;
        lower[i] = NO_ENTRY;
        Node* l = trail->array[i].lhs.n;
        if(l == NULL)
        {
            continue;
        }
        Node* r = trail->array[i].rhs.n;
        if(r != NULL && (r->gc_bits & GC_TRAILED))
        {
            clear_trailed_all(size);
            return;
        }
        Versions* v = find_versions(l, true);
        lower[i] = v->top;
        v->top = i;
        v->versions++;
        v->unreached++;
    }
    for(size_t k = 0; k < recs_n; k++)
    {
        size_t j = recs[k].top;
        while(j != NO_ENTRY && j >= commit_min)
        {
            j = lower[j];
        }
        recs[k].b_below = j == NO_ENTRY ? 0 : seg_b[j];
    }

    // Trace from the roots, which see every view.
    live_n = 0;
    if(partial_n > 0)
    {
        memset(partial, 0, partial_cap * sizeof(Partial));
        partial_n = 0;
    }
    live_reach(root.n, 0, size);
    size_t lo = size;
    for(Frame* f = sp; (union field*)f < rice_stack_hi;
        f = (Frame*)((union field*)f + 1 + f->info->size))
    {
        lo = frame_views(f, lo);
        for(unsigned short i = 0; i < f->info->size; i++)
        {
            if(field_rep(f->info->reps, i) == R_PTR)
            {
                live_reach(f->slots[i].n, lo, size);
            }
        }
    }
    for(size_t i = 0; i < gc_nroots; i++)
    {
        live_reach(gc_roots[i]->n, 0, size);
    }
    while(live_n > 0)
    {
        LiveItem it = live_work[--live_n];
        live_scan(it.n, it.lo, it.hi);
    }
    clear_trailed_all(size);

    // D3
    size_t placeholders = 0;
    for(size_t k = 0; k < recs_n; k++)
    {
        Versions* v = &recs[k];
        if(!v->current && v->unreached < v->versions)
        {
            Node* l = v->node;
            l->symbol = &gc_dead_symbol;
            l->missing = 0;
            for(int c = 0; c < 4; c++)
            {
                l->children[c].n = NULL;
            }
            placeholders++;
        }
    }

    // D2 and D4, then compact.
    size_t kept = 0, emptied = 0;
    for(size_t i = 0; i < size; i++)
    {
        kept_below[i] = kept;
        TrailEntry e = trail->array[i];
        if(e.lhs.n == NULL || !reached[i])
        {
            if(seg_a[i] != i)
            {
                continue;
            }
            if(e.lhs.n != NULL)
            {
                emptied++;
            }
            e.lhs.n = NULL;
            e.rhs.n = NULL;
        }
        trail->array[kept++] = e;
    }
    kept_below[size] = kept;
    remap_frame_heights(sp, size);
    trail->size = kept;
    if(trail->clean > kept)
    {
        trail->clean = kept;
    }
#ifdef GC_STATS
    fprintf(stderr, "gc liveness: %zu entries, %zu kept (%zu emptied), %zu nodes, "
                    "%zu placeholders, %zu partly reached\n",
            size, kept, emptied, recs_n, placeholders, partial_n);
#else
    (void)emptied;
    (void)placeholders;
#endif
}
#endif
#endif

// Copy everything live into a new old generation.
static union field collect_major(union field root, Frame* sp)
{
#ifndef GC_NO_TRAIL_COMPACT
    compact_trail(sp);
#ifndef GC_NO_TRAIL_LIVENESS
    trail_liveness(root, sp);
#endif
#endif
    minor = false;
    work.live_bytes = 0;
    void* from_space = heap_begin_major();
    root = copy_reachable(root, sp);
    heap_end_major(from_space);
    old_bytes = work.live_bytes;
    // Collect the old generation again once it has doubled.
    // That keeps the cost of major collections proportional to how much we promote.
    old_threshold = 2 * work.live_bytes;
    if(old_threshold < GC_MIN_THRESHOLD)
    {
        old_threshold = GC_MIN_THRESHOLD;
    }
    trail_threshold = 2 * trail->size;
    if(trail_threshold < GC_MIN_TRAIL)
    {
        trail_threshold = GC_MIN_TRAIL;
    }
    debug(LOW, "gc: %zu bytes live\n", work.live_bytes);
#ifdef GC_STATS
    fprintf(stderr, "gc major: %zu bytes live, next at %zu, %zu trail entries\n",
            work.live_bytes, old_threshold, trail->size);
#endif
    return root;
}

// actually run the collector: a minor collection, then a major one if the
// old generation or the trail has grown past its threshold.
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
    bool major = old_bytes > old_threshold || trail->size > trail_threshold;
#endif
    if(major)
    {
        root = collect_major(root, sp);
    }

    mem = saved_mem;
    rice_bytes_since_gc = 0;
    return root;
}
