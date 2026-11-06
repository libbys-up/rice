#ifndef TRAIL_H
#define TRAIL_H

#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "node.h"

/* The trail records every in-place rewrite we might need to undo when we backtrack.
 *
 * If you know the WAM, be careful here: we don't have a separate choice point stack.
 * A choice point is just a trail entry with choice == true.
 * undo() (runtime.c) pops entries, copying rhs back over lhs,
 * until it pops a choice entry.
 * That's where the search resumes with the other alternative.
 */

// Initial number of entries in the trail.
#define TRAIL_INIT_CAPACITY 20

/* One trail entry.
 *  * lhs: the node that was rewritten.
 *  * rhs: a copy of what lhs looked like before the rewrite.
 *         undo() memcpys this back over lhs.
 *  * choice: true if this entry is a choice point.
 *            Backtracking stops after restoring this entry.
 *  * epoch: the value of current_epoch when this entry was pushed,
 *           so popping the entry can restore it.
 *           This is only meaningful with OPT_EPOCH_TRAIL,
 *           but we always keep it so trail.c doesn't need an #if.
 */
typedef struct TrailEntry
{
    bool choice;
    field lhs;
    field rhs;
    unsigned int epoch;
} TrailEntry;

// The trail itself is just a growable array of entries.
//  * clean: the entries below this height point only at old nodes, and
//    haven't been popped since a collection found that. A minor collection
//    can't move old nodes, so it skips them (gc.c). Popping below it lowers
//    it, since the entries pushed after that are new.
typedef struct
{
    TrailEntry* array;
    size_t size;
    size_t capacity;
    size_t clean;
} Trail;

Trail* trail_new(void);

void trail_push(Trail* s, union field from, union field rep, bool choice);

// Pop the newest entry.  The caller is responsible for restoring it.
TrailEntry* trail_pop(Trail* s);

/* Throw away every entry above height n without restoring any of them.
 * bindIO uses this to commit to the choices made while running an IO action.
 */
TrailEntry* trail_pop_to(Trail* s, int n);

// Inline: case blocks read the size to mark their cutoff under OPT_SCOPED_BACKTRACK.
static inline bool trail_empty(Trail* s)
{
    return s->size == 0;
}

static inline int trail_size(Trail* s)
{
    return s->size;
}

#endif // TRAIL_H
