
Structure of Compiled Curry code
=================================

The curry graph is made up of Node objects.
A node consists of
  * missing: If this is a partial function, then it is the number of missing children.
             otherwise this is 0
  * nondet:  if this node depends on a non-deterministic value.
             All nodes start with a nondet of false (even choice nodes),
             but this can change as we evaluate the node.
  * symbol: a pointer to the symbol table which contains static information about the node.
  * children: an array of Node pointers.
              Each node has an array of 4 children, 
              but the last child is reserved to point to an array
              if a node has more than 3 children.

A symbol consists of 
  * `tag`: one of FAIL TAG, FUNCTION TAG, CHOICE TAG, FORWARD TAG, FREE TAG
           or a constructor tag
  * `arity`: the number of arguments the node takes
  * `name`: A string representation of the node used for debugging
  * `hnf`: a function pointer to a redution function
  * possiby `hnf_RET`: a reduction function for the if the node is the scrutinee
                       of a case expression
                       This is a useful optimization, but it really complicates the code.

Because this compiler supports unboxing, one of the children of a node
can be a literal long (for Int), unsigned long (for Char), or double (for Float).
The last child is also an array of `Node*`.
to support this, we have a field union:
```
typedef union field
{
    struct Node*  n; //normal node child
    union field*  a; //array child (for children[3])
    unsigned long c; //primitive character
    long          i; //primitive int
    double        f; //primitive float
} field ;
```
This means that `children` is not actually a `Node*[4]`, but really a `field[4]`
 

A Node can have up to 50 children,
However we want to have all nodes have a uniform layout.
So be default each node has 3 children.
any child after the third is stored in an auxillary array.
So, we can get the second child with
```n->children[1]```
but the fifth child is
```n->children[3].a[1]```

It's inconvenient to have to make this distinction,
so the runtime system has a macro
```child_at(node, index)```
that handles this.

There are 4 varients of this
```child_at_n(r, k)```
```child_at_i(r, k)```
```child_at_c(r, k)```
```child_at_f(r, k)```
```child_at_a(r, k)```
These are functionally the same as `child_at`, but give you back the field as a
`Node*`, `Int`, `Char`, `Float`, or field array respectively.


There is also child_at_v(node,index) for when the index is not a constant.
This is not recommended, because we actually have to do some computation at runtime,
but it is necessary sometimes.

Variables 
=========

Variables are all uniquely numbered starting with 2
Variable 0 is reserved as a reference to the root node.

Variable 1 is reserved as a reference to the scrutinee of a case.
This is used exclusively for the case shortcutting optimization
In case shortcutting, a variable with a negative index is used a variable
that is used as the scrutinee of a case, and nowhere else.

Case Shortcutting
=================

case shortcutting is a very simple optimization in Haskell,
but turns out to be obnoxious in Curry.
The idea is
case x || y of
  True -> ...
  False -> ...

I don't really need the node for x || y.
I just need the result, So I don't want to construct this node.
The solution that I've come up with is to have a static node called RET (for return).
I'll put the arguments in RET, and I can look at RET's tag after I evaluate it.
This works because I never have partially overlapping of case expressions.
So I never have a case where I have RET representing two different expressions at the same time.
** This needs justification **

This would be great, except for the fact that the scrutinee of a case might be non-deterministic.
If that's the case, I need to put _something_ on the backtracking stack.
The solution I came up for was that I have 2 hnf functions for each node type.
 * foo_hnf is the normal hnf function that takes a node, and reduces the node
 * foo_hnf_backup assumes that our root node is RET.
   It does the normal reduction, but if the node is non-deterministic,
   we allocate a new node that's a copy of the reduced version of RET.
   This is the node we put on the backtracking stack.
