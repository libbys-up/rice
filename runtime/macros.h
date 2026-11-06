#ifndef MACROS_H
#define MACROS_H

#include "node.h"

/* Child k of node r, as an lvalue: children 0-2 are in the node, and
 * children 3 and up are in its spill array. Used to implement child_at in
 * runtime.h. k is a constant there, so the compiler folds the test away;
 * the inner (k) < 3 ? (k) : 0 keeps the untaken branch's index in bounds,
 * so it doesn't draw an array-bounds warning.
 */
#define CHILD_AT(r, k) \
    (*((k) < 3 ? &(r)->children[(k) < 3 ? (k) : 0] : &(r)->children[3].a[(k) - 3]))

#endif // MACROS_H
