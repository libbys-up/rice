#ifndef GC_H
#define GC_H

/* This is a 2 space copy collector over a block structured heap.
 * This mean:
 *  * We split memory into "from space" and "to space"
 *    When we run garbage collection, we copy everything from "from space" to "to space"
 *    Then we delete "from space"
 *  * Memory is allocated in blocks (we call them chunks, see memory.h)
 *    So, we don't actually have a "to space" at any given time.
 *    When we run the garbage collector, we allocate new chunks to move the objects into,
 *    then we free all of the chunks in "from space".
 *  * Allocation itself never collects.
 *    C code all over the runtime holds raw Node* pointers that the collector can't see,
 *    so moving nodes in the middle of an allocation would leave those pointers dangling.
 *    Instead, each _hnf function starts with a safe point (GC_SAFE_POINT).
 *    There, the only live pointers are ones the collector can find,
 *    so if we've allocated enough since the last collection, we collect there.
 *    This means the threshold is a soft limit: we can go past it until the next safe point.
 *  * Our root set is the root node we're reducing, the frames on the machine stack,
 *    the trail, and any C roots (GC_ROOT, below).
 */

#include <stddef.h>
#include <string.h>
#include "node.h"
#include "machine.h"
#include "memory.h"

// Collect when this many bytes have been allocated since the last
// collection: the nursery's size (GC_NURSERY_BYTES, below). Under GC_STRESS
// it's 0, so we collect at every safe point.
extern size_t rice_heap_threshold;

// A major collection runs when the old generation has doubled since the
// last one, but never before it reaches this size.
#ifndef GC_MIN_THRESHOLD
#define GC_MIN_THRESHOLD ((size_t)64 << 20)
#endif

// A major collection also runs when the trail has doubled since the last
// one (gc.c), but never before it has this many entries.
#ifndef GC_MIN_TRAIL
#define GC_MIN_TRAIL ((size_t)1 << 16)
#endif

/* Generations (gc-plan.md, stage 7).
 * Everything is allocated in the nursery. A minor collection, when the
 * nursery is full, copies the young nodes that are alive: a node's first
 * survival moves it to the survivor space, still young, and its second
 * promotes it to the old generation. A major collection copies everything.
 */
#ifndef GC_NURSERY_BYTES
#define GC_NURSERY_BYTES ((size_t)8 << 20)
#endif

// Bits in Node.gc_bits. (2 and 4 are OPT_STATS's, in runtime.h.)
#define GC_TRAILED    1   // on the trail; only set during a collection
#define GC_REMEMBERED 8   // old, and in the remembered set
#define GC_OLD        16  // in the old generation
#define GC_AGED       32  // young, and has lived through a minor collection
#define GC_VISITED    64  // GC_VERIFY's walk, or trail_liveness's, has reached it (gc.c)
#define GC_SEEN       128 // compact_trail: has an entry lower in this segment
#define GC_AGE_BITS   (GC_TRAILED | GC_REMEMBERED | GC_OLD | GC_AGED)

// A spill array's header word once the array is in the old generation.
// It's NULL while the array is young, and during a collection it holds the
// address of the array's copy.
#define GC_OLD_ARRAY ((union field*)1)

/* The write barrier.
 * Rewriting a node in place can make an old node point at a young one,
 * which a minor collection wouldn't otherwise see, since it doesn't scan
 * the old generation. So everything that writes pointers into a node that
 * already existed calls gc_remember on it first. An old node that isn't
 * remembered yet goes in the remembered set, which a minor collection
 * scans. A young node needs nothing, and that's the common case.
 */
void gc_remember_slow(Node* n);

static inline void gc_remember(Node* n)
{
    if((n->gc_bits & (GC_OLD | GC_REMEMBERED)) == GC_OLD)
    {
        gc_remember_slow(n);
    }
}

// How many children of n live in its spill array: children 3 and up.
// An apply node has nargs + 1 children (the function, then the arguments);
// an ordinary node has arity children.
static inline int gc_spill_len(const Node* n)
{
    int count = n->missing < 0 ? -n->missing + 1 : (int)n->symbol->arity;
    return count > 3 ? count - 3 : 0;
}

// Copy src's contents over dst, a node that already existed. dst keeps its
// own place in the generations; its other contents, epoch and nondet
// included, become src's.
static inline void node_overwrite(Node* dst, const Node* src)
{
    unsigned char keep = dst->gc_bits & GC_AGE_BITS;
    memcpy(dst, src, sizeof(Node));
    dst->gc_bits = (unsigned char)((dst->gc_bits & ~GC_AGE_BITS) | keep);
    gc_remember(dst);
}

// Copy src's contents into dst, a node just allocated, which is young
// whatever src is.
static inline void node_copy_fresh(Node* dst, const Node* src)
{
    memcpy(dst, src, sizeof(Node));
    dst->gc_bits &= (unsigned char)~GC_AGE_BITS;
}

/* Copies everything reachable from 
 *  * root
 *  * the frames from `sp` up
 *  * the trail
 *  * the C roots: which are function specific local variables that we may need to track.
 * 
 * Then we free the old chunks.
 *
 * Return the new address of root.
 *
 * Stack frames and the trail are updated to point to new objects.
 */
union field gc_collect(union field root, Frame* sp);

// Check if we actually need to run the collector.
// This can move root, so it assigns the new address back into root.
// Use standard do { ... } while(0)
// trick to make this act like a statement.
#define GC_SAFE_POINT(root, sp)                                  \
    do {                                                         \
        if(rice_heap_since_gc > rice_heap_threshold)             \
        {                                                        \
            (root) = gc_collect((root), (sp));                   \
        }                                                        \
    } while(0)

/* C roots: 
 * Because some of the C in functions like eval_hnf, nf, settle ... 
 * may have local variables that we need to keep updated,
 * we register them as roots for the garbage collector.
 * If the collector runs, then we'll update the roots.
 * Machine code doesn't need these: across an evaluation its state is in a frame.
 *
 * In the code this is done with calls to
 * GC_ROOT(field root)
 * and 
 * GC_UNROOT(int numRoots)
 */
extern union field** gc_roots;
extern size_t        gc_nroots;
extern size_t        gc_roots_cap;
void gc_roots_grow(void);

// add a new C root
static inline void gc_push_root(union field* r)
{
    if(gc_nroots == gc_roots_cap)
    {
        gc_roots_grow();
    }
    gc_roots[gc_nroots] = r;
    gc_nroots++;
}

#define GC_ROOT(x)   gc_push_root(&(x))
#define GC_UNROOT(n) (gc_nroots -= (n))

#endif // GC_H
