#ifndef NODE_H
#define NODE_H

#include<stdbool.h>

struct Node;

typedef union field
{
    struct Node*  n; //normal node child
    union field*  a; //array child (for children[3])
    unsigned long c; //primitive character
    long          i; //primitive int
    double        f; //primitive float
} field;

// What does a constructor's single "payload" child actually hold?
// PAYLOAD_NONE means an ordinary Node* child (the common case -- every
// user-defined constructor). The other three mark the boxed Int/Char/Float
// wrapper constructors codegen generates: their one child holds a raw C
// value directly (no separate wrapper node for *that*), and this is how
// generic code (printing, unify, nf/ground_nf) tells which raw
// interpretation applies without needing a per-node discriminant -- it's a
// fact about the constructor, so it lives on the Symbol, set once at
// codegen time alongside .tag/.arity/.name. See archetecture.md's "Boxed
// primitives, and the Symbol.payload design" for the full writeup,
// including a sketched generalization of this to a per-child-slot array,
// for a future where nodes can mix boxed and unboxed children and a
// tracing GC needs to know which child slots are real pointers.
typedef enum { PAYLOAD_NONE, PAYLOAD_INT, PAYLOAD_CHAR, PAYLOAD_FLOAT } Payload;

typedef struct
{
    const unsigned char tag;
    const unsigned int arity;
    const char* name;
    const Payload payload;
    void (*hnf)(union field);
    struct Node* (*hnf_RET)(struct Node*);
} Symbol;


typedef struct Node
{
    int missing;
    bool nondet;
    Symbol* symbol;
    union field children[4];
} Node;

#endif // NODE_H
