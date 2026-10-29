#ifndef NODE_H
#define NODE_H

#include<stdbool.h>
#include<stdint.h>

/* A Node represents a single expression node.
 * Our heap is really a graph defined by these nodes.
 * Each node can have 0 or more pointers to child nodes,
 * but this is a graph, so the child nodes can loop back around.
 *
 * A Node has several technical pieces, but the important parts are
 * * symbol: A pointer to a static symbol telling us which node type we are
 * * children[4]: a pointer to each of the children of the node.
 *
 * Nearly all nodes have 3 or fewer children.
 * When a node has more than 3, the 4th slot is reserved to be a pointer
 * to a longer array of children.
 * The curry term (let x = True in xor4 x x x x)
 * would be represented as
 * Node* x = Node {symbol=True, children={}}
 * Node** arr = {x}
 * Node {symbol=xor4, children={x,x,x,arr}}
 * 
 */
struct Node;

/* To accommodate primitive values, we usually work with fields instead of nodes.
 * A field is either
 *  * a pointer to a node
 *  * a char (represented as unsigned long for unicode)
 *  * a int  (represented as a signed long)
 *  * a float (represented as a double)
 *  * or an array of fields
 * This last representation is the array for if our node has more then 3 children.
 *
 * This means that a node's children are fields instead of nodes.
 * So a boxed Int(7) is really
 * Node {symbol = Int, children = {7, NULL, NULL, NULL}}
 */
typedef union field
{
    struct Node*  n; //normal node child
    union field*  a; //array child (for children[3])
    unsigned long c; //primitive character
    long          i; //primitive int
    double        f; //primitive float
} field;

/* Field is convenient for representation, but we lose type information.
 * This is ok for evaluate, but its a real problem for the garbage collector.
 * We don't want it trying to follow an Int like a pointer.
 * To solve this, each symbol has a list of representations, so the garbage collector
 * can look up what type each child is.
 * The code generator computes these in Rice.Codegen.FieldReps.
 *
 * The possibilities are
 *  * R_PTR       Node pointer
 *  * R_INT       unboxed Int
 *  * R_CHAR      unboxed Char
 *  * R_FLOAT     unboxed Float
 *
 * Because most (nearly all without unboxing) children are pointers,
 * we make the convention that if the FieldRep array is NULL, all children are pointers.
 * This lets us efficiently check the common case with !reps
 *
 * There are a couple of caveats
 * 1. Choice has a field to mark which side of the choice we took.
 *    This is not represented in Reps, because it's always a primitive
 * 2. partial applications don't have all of their arguments,
 *    so they only have (arity-missing) reps.
 * 3. apply nodes don't use reps at all.
 * 4. When doing a rewrite all reps are replaced at the same time with the node's symbol.
 */
typedef enum
{
    R_PTR = 0,  // pointer to a node
    R_INT,      // raw long   (union field .i)
    R_CHAR,     // raw char   (union field .c)
    R_FLOAT     // raw double (union field .f)
} FieldRep;

/*
 * Clang 19 supports preserve_none which allows us to do tail calls without
 * having to preserve callee saved registers.
 * This works out for us because we've engineered the hnf functions
 * to be entirely tail calls.
 *
 * If the compiler doesn't support preserve_none,
 * then we just have the normal C calling conventions.
 * It's at most about 6% slower, so it's still very usable.
 */
#if defined(__has_attribute)
#  if __has_attribute(preserve_none)
#    define RICE_CC __attribute__((preserve_none))
#  endif
#endif
#ifndef RICE_CC
#  define RICE_CC
#endif

/* Machine code (machine.h): an _hnf function, a case block,
 * or a continuation.
 * We don't evaluate with ordinary C calls, because the C stack is too small
 * for deeply recursive programs. Instead we keep our own stack of frames,
 * and machine code only ever jumps.
 * So every piece of machine code takes
 *  1. root, the node we're reducing, and
 *  2. sp, the top of our stack,
 * which C passes in registers:
 * void foo_hnf(union field root, struct Frame* sp)
 * See the developer's manual, "The evaluation machine".
 */
struct Frame;
typedef RICE_CC void (*Code)(union field root, struct Frame* sp);

/* The symbol holds all of the static information about a node.
 *  * tag: This determines what kind of node we have
 *      FAIL_TAG
 *      FUNCTION_TAG
 *      CHOICE_TAG
 *      FORWARD_TAG
 *      FREE_TAG
 *      All other tags are used for constructors of a specific type
 *      For example True_TAG and False_TAG for Bool
 *   * arity: the number of children in a node
 *            For apply nodes this is 0.
 *   * name: The name of the node for debugging and printing.
 *   * reps: The FieldRep array for the node.
 *           Because C11 gives enums 4 bytes by default, it's more compact
 *           to save each rep as a single byte, and cast it later.
 *           child_rep does that cast, and checks our NULL convention at the same time.
 *   * hnf:  The Code to reduce the node to head normal form.
 *   * hnf_RET: This isn't currently used, but it came from the case shortcutting optimization.
 *              The idea is that if we make an expression that is immediately reduced in a case,
 *              then we can store that expression in a single static node without
 *              having to do any allocation.
 *              This would need a different signature for the _hnf function,
 *              so we have to store a second pointer here.
 */
typedef struct
{
    const unsigned char tag;
    const unsigned int arity;
    const char* name;
    const unsigned char* reps;
    Code hnf;
    struct Node* (*hnf_RET)(struct Node*);
} Symbol;

/* Get rep i out of a reps array (a Symbol's or a FrameInfo's).
 * We store reps as bytes to save space, but work with them as FieldReps,
 * and a NULL array means every entry is a pointer.
 */
static inline FieldRep field_rep(const unsigned char* reps, int i)
{
    if(reps == NULL)
    {
        return R_PTR;
    }
    else
    {
        return (FieldRep)reps[i];
    }
}

// The rep of child i of a node with symbol s.
static inline FieldRep child_rep(const Symbol* s, int i)
{
    return field_rep(s->reps, i);
}

/* Finally we can define a node
 * A node contains the information to reduce an expression to head normal form
 *   * symbol: The symbol of static information, defined above
 *   * children[4]: the pointers to the children nodes.
 *                  The 4th child is reserved so it can extend the array
 *                  if we have more than 3 children.
 *   * missing: if we're a fully applied node, then this is always 0.
 *              If we're partially applied, then this is n > 0, where n is the number
 *              of arguments we still need to be fully applied.
 *              If we're an apply node specifically, then this is -n < 0,
 *              where n is the number of arguments we're applying.
 *   * nondet:  true if this node's value depends on a choice we might backtrack over.
 *              Every node starts out false (even choice nodes).
 *              A node becomes nondet when a choice touches it, or when we read
 *              a nondet node while rewriting it.
 *              We only need to trail a rewrite if it read something nondet.
 *   * gc_bits: Information that's only used by the garbage collector,
 *              and is always 0 outside of a collection.
 *              Right now the only bit is GC_TRAILED (gc.c):
 *              the node is the left hand side of a trail entry.
 *              The collector skips over FORWARD nodes it doesn't need,
 *              but a trailed node might be turned back into something else by undo(),
 *              so it has to stay.
 *              This fits in the padding after nondet, so it costs no space.
 *   * epoch: If we're doing the epoch trailing optimization, 
 *            this stores the current timestamp that the node was created.
 *            If we were created after the last choice point,
 *            then we don't need to record any rewrites onto the trail.
 *            This is under an #if because we don't want to do this bookkeeping
 *            if the optimization is turned off.
 *
 * missing, nondet, gc_bits and epoch share the first word, so a node is
 * six words either way. That's why missing is only 16 bits: as an int, it
 * would push epoch, and so every node, out to a seventh word.
 * Nodes are most of what a program allocates, so that costs time everywhere.
 */
typedef struct Node
{
    int16_t missing;
    bool nondet;
    unsigned char gc_bits;
#if OPT_EPOCH_TRAIL
    unsigned int epoch;
#endif
    Symbol* symbol;
    union field children[4];
} Node;

_Static_assert(sizeof(Node) == 6 * sizeof(union field),
               "a node must stay six words; see the comment above");

#endif // NODE_H
