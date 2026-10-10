#include<stddef.h>
#include<stdio.h>
#include<stdbool.h>
#include<stdlib.h>
#include<string.h>

#include "node.h"
#include "stack.h"
#include "debug.h"
#include "runtime.h"
#include "memory.h"

// The trail is runtime-owned memory, not part of the garbage-collected
// heap: malloc, not alloc. (Its entries point into the heap and are GC
// roots; the array itself never moves under the collector.)
Stack* new_stack()
{
    Stack* s = (Stack*)malloc(sizeof(Stack));
    s->size = 0;
    s->capacity = INIT_CAPACITY;
    s->array = (FieldPair*)malloc(sizeof(FieldPair)*INIT_CAPACITY);
    return s;
}


void stack_push(Stack* s, union field from, union field rep, bool choice)
{
    if(s->size == s->capacity)
    {
        s->capacity *= 2;
        s->array = (FieldPair*)realloc(s->array, s->capacity * sizeof(FieldPair));
        if(s->array == NULL)
        {
            fprintf(stderr, "Error: can't grow the backtracking stack\n");
            exit(1);
        }
    }
    s->array[s->size].choice = choice;
    s->array[s->size].lhs = from;
    s->array[s->size].rhs = rep;
    s->array[s->size].epoch = current_epoch;
    debug(HIGH, "pushing ");
    debug_frame(HIGH, &s->array[s->size]);
    debug(HIGH, "\n");
    s->size++;
}

// pop one FieldPair off the stack
FieldPair* pop(Stack* s)
{
    s->size--;
    current_epoch = s->array[s->size].epoch;
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
    current_epoch = s->array[s->size].epoch;
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
