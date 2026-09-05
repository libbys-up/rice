#include<stddef.h>
#include<stdbool.h>
#include<stdlib.h>
#include<string.h>

#include "node.h"
#include "stack.h"
#include "debug.h"
#include "runtime.h"
#include "memory.h"

Stack* new_stack()
{
    Stack* s = (Stack*)alloc(sizeof(Stack));
    s->size = 0;
    s->capacity = INIT_CAPACITY;
    s->array = (FieldPair*)alloc(sizeof(FieldPair)*INIT_CAPACITY);
    return s;
}


void stack_push(Stack* s, union field from, union field rep, bool choice)
{
    if(s->size == s->capacity)
    {
        int size = s->capacity*sizeof(FieldPair);
        FieldPair* new_array = (FieldPair*)alloc(2*size);
        memcpy(new_array, s->array, size);
        s->capacity *= 2;
#ifdef GC
        // GC_MALLOC'd memory is collector-managed; calling the ordinary
        // free() on it is undefined behavior. Just drop the old array --
        // the collector reclaims it once nothing references it, same as
        // any other GC_MALLOC'd block that goes out of scope.
#else
        free(s->array);
#endif
        s->array = new_array;
    }
    s->array[s->size].choice = choice;
    s->array[s->size].lhs = from;
    s->array[s->size].rhs = rep;
    debug(HIGH, "pushing ");
    debug_frame(HIGH, &s->array[s->size]);
    debug(HIGH, "\n");
    s->size++;
}

// pop one FieldPair off the stack
FieldPair* pop(Stack* s)
{
    s->size--;
    debug_frame(HIGH, &s->array[s->size]);
    debug(HIGH, "\n");
    return &s->array[s->size];
}

// backtrack until we get to the remembered point on the stack.
// This is used in EARLY_BACKTRACKING to backtrack to undo upto a certian point.
// I'm not entirely sure if I need this.
FieldPair* pop_to(Stack* s, int n)
{
    // n is always a previously-recorded stack size (see size(), which
    // returns int for the same reason cutoff does in undo()), so this
    // never actually compares against a negative n in practice.
    if(n < 0 || s->size <= (size_t)n)
    {
        return NULL;
    }
    s->size = n;
    debug_frame(HIGH, &s->array[s->size]);
    debug(HIGH, "\n");
    return &s->array[s->size];
}

bool empty(Stack* s)
{
    return s->size == 0;
}

int size(Stack* s)
{
    return s->size;
}
