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
