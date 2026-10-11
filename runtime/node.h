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

// How each child of a node is represented: a pointer to another node, or a
// raw primitive value stored directly in the `union field`. A Symbol's
// `reps` array has one entry per child slot in [0, arity); a NULL `reps`
// means every child is a pointer, which is the common case and costs no
// data. Generated symbols get their arrays from the compiler's field-rep
// table (Rice.Codegen.FieldReps, src/field-reps-plan.md).
//
// Rules every child walker (and later the GC) relies on:
//   * only slots in [0, arity) are described; a slot at or past `arity`
//     (choice_symbol's raw `side` in slot 2, for instance) must never
//     hold a pointer;
//   * a partial application (missing > 0) has filled only its first
//     arity - missing slots; the last `missing` are NULL until apply_hnf
//     fills them (filled_arity(), runtime.h). An `apply` node
//     (missing < 0) has arity 0 and keeps its arguments outside this
//     scheme entirely -- see apply_hnf;
//   * a node's children always match its *current* symbol -- a rewrite
//     replaces symbol and children together, never one child's rep alone.
typedef enum
{
    R_PTR = 0,  // pointer to a node
    R_INT,      // raw long   (union field .i)
    R_CHAR,     // raw char   (union field .c)
    R_FLOAT     // raw double (union field .f)
} FieldRep;

// Calling convention for machine code. preserve_none (clang 19+) makes a
// tail jump cost no callee-saved register traffic; elsewhere it's left
// out, which is still correct, just slower.
#if defined(__has_attribute)
#  if __has_attribute(preserve_none)
#    define RICE_CC __attribute__((preserve_none))
#  endif
#endif
#ifndef RICE_CC
#  define RICE_CC
#endif

// A piece of machine code (machine.h): a `_hnf` function, a case block, or
// a runtime routine. It takes the machine's two registers as arguments --
// the node being reduced and the stack pointer -- so they stay in machine
// registers across every tail jump. Every piece has this one signature,
// which is what lets any of them tail-call any other.
struct Frame;
typedef RICE_CC void (*Code)(union field root, struct Frame* sp);

typedef struct
{
    const unsigned char tag;
    const unsigned int arity;
    const char* name;
    const unsigned char* reps; // FieldRep per child, or NULL for all pointers
    Code hnf;  // reduces rice_root to head normal form
    struct Node* (*hnf_RET)(struct Node*);
} Symbol;


typedef struct Node
{
    int missing;
    bool nondet;
    // Scratch bits for the collector (gc.c), clear outside a collection.
    // Fits in the padding after nondet.
    unsigned char gc_bits;
#if OPT_EPOCH_TRAIL
    // Allocation-order stamp for backtracking-optimizations.md's #5: set
    // once, when this exact memory is first allocated (never touched by
    // an in-place rewrite of its contents -- see runtime.c's set_copy),
    // compared against the active choice point's own stamp (current_epoch,
    // runtime.h) to tell whether backtracking past that choice point would
    // make this node unreachable on its own, without needing a trail
    // frame. Conditional on the same flag that uses it so a build that
    // doesn't enable #5 doesn't pay for it -- OPT_EPOCH_TRAIL is a
    // command-line -D (or runtime.h's own default), visible before this
    // header is processed either way, so its value here always matches
    // whatever the rest of the same build was compiled with.
    unsigned int epoch;
#endif
    Symbol* symbol;
    union field children[4];
} Node;

#endif // NODE_H
