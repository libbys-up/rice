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
#include "node.h"
#include "machine.h"
#include "memory.h"

// Collect when this many bytes have been allocated since the last collection.
// When we run with GC_STRESS, this is set to 0, so we collect at every safe point.
extern size_t rice_heap_threshold;

// The threshold never drops below 64MB.
#define GC_MIN_THRESHOLD ((size_t)64 << 20)

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
