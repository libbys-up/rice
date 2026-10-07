#ifndef STACK_H
#define STACK_H

#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "node.h"

// Initial backtracking stack capacity.
#define INIT_CAPACITY 20

typedef struct FieldPair
{
    bool choice;
    field lhs;
    field rhs;
    // backtracking-optimizations.md's #5: current_epoch's (runtime.h)
    // value at the moment this frame was pushed, restored when it's
    // popped (stack.c) -- present unconditionally (not just under
    // OPT_EPOCH_TRAIL) so stack_push/pop never need their own #if: when
    // #5 is off, current_epoch never moves from 0, so snapshotting and
    // restoring it here is just an inert round-trip through this field,
    // not dead weight worth special-casing away. choose()/push_choice()
    // (runtime.c) are the only place this value ever *changes* (once per
    // choice point, not per push), so this correctly unwinds in lockstep
    // with the stack regardless of whether a given frame is choice-marked
    // or an ordinary trail entry.
    unsigned int epoch;
} FieldPair;

typedef struct
{
    FieldPair* array;
    size_t size;
    size_t capacity;
} Stack;

Stack* new_stack();

void stack_push(Stack* s, union field from, union field rep, bool choice);

FieldPair* pop(Stack* s);

FieldPair* pop_to(Stack* s, int n);

bool empty(Stack* s);

int size(Stack* s);

#endif
