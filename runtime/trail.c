#include<stddef.h>
#include<stdio.h>
#include<stdbool.h>
#include<stdlib.h>
#include<string.h>

#include "node.h"
#include "trail.h"
#include "debug.h"
#include "runtime.h"
#include "memory.h"

// The trail lives in malloc'd memory, not the garbage collected heap.
// Its entries point into the heap, so the collector treats them as roots,
// but the collector never moves the array itself.
Trail* trail_new(void)
{
    Trail* s = (Trail*)malloc(sizeof(Trail));
    s->size = 0;
    s->capacity = TRAIL_INIT_CAPACITY;
    s->array = (TrailEntry*)malloc(sizeof(TrailEntry)*TRAIL_INIT_CAPACITY);
    return s;
}


void trail_push(Trail* s, union field from, union field rep, bool choice)
{
    if(s->size == s->capacity)
    {
        s->capacity *= 2;
        s->array = (TrailEntry*)realloc(s->array, s->capacity * sizeof(TrailEntry));
        if(s->array == NULL)
        {
            fprintf(stderr, "Error: can't grow the trail\n");
            exit(1);
        }
    }
    s->array[s->size].choice = choice;
    s->array[s->size].lhs = from;
    s->array[s->size].rhs = rep;
    s->array[s->size].epoch = current_epoch;
#if OPT_STATS
    opt_stats.trail_pushes++;
    opt_stats.choice_points += choice;
    if(s->size + 1 > opt_stats.max_trail)
    {
        opt_stats.max_trail = s->size + 1;
    }
#endif
    debug(HIGH, "pushing ");
    debug_trail_entry(HIGH, &s->array[s->size]);
    debug(HIGH, "\n");
    s->size++;
}

// Pop one entry off the trail.
TrailEntry* trail_pop(Trail* s)
{
    s->size--;
    // We're undoing back to this entry, so the epoch goes back to what it was then.
    current_epoch = s->array[s->size].epoch;
    debug_trail_entry(HIGH, &s->array[s->size]);
    debug(HIGH, "\n");
    return &s->array[s->size];
}

// Drop every entry above height n, without restoring them.
TrailEntry* trail_pop_to(Trail* s, int n)
{
    // n is always a height we recorded earlier, so it's never negative in practice.
    if(n < 0 || s->size <= (size_t)n)
    {
        return NULL;
    }
    s->size = n;
    current_epoch = s->array[s->size].epoch;
    debug_trail_entry(HIGH, &s->array[s->size]);
    debug(HIGH, "\n");
    return &s->array[s->size];
}

bool trail_empty(Trail* s)
{
    return s->size == 0;
}

int trail_size(Trail* s)
{
    return s->size;
}
