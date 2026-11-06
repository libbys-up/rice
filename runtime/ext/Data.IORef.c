// The externals of Data.IORef.
//
// IORef is an external data type, so it has no constructor in the
// generated code. A ref is a node with ioref_symbol whose one field points
// at a cell, a node with cell_symbol whose one field is the value. A write
// changes the cell, never the ref: the ref is an ordinary constructor
// node, which copy collapsing and set_copy are free to duplicate, and
// every copy has to see the same writes. Both tags are the first
// constructor tag; IORef has no cases.
//
// Writes aren't trailed. A write is an IO action, and IO never backtracks:
// bindIO commits to everything an action did (ext/Prelude.c).

#include "ext.h"
#include "Data/IORef.h"

static const unsigned char ioref_reps[] = { R_PTR };
static Symbol ioref_symbol =
    { .tag = FREE_TAG + 1, .arity = 1, .name = "IORef",
      .reps = ioref_reps, .hnf = &CTR_hnf };
static Symbol cell_symbol =
    { .tag = FREE_TAG + 1, .arity = 1, .name = "IORef cell",
      .reps = ioref_reps, .hnf = &CTR_hnf };

static field mk_node1(Symbol* symbol, field child)
{
    field n;
    n.n = (Node*)alloc(sizeof(Node));
    #if OPT_EPOCH_TRAIL
    n.n->epoch = current_epoch;
    #endif
    n.n->symbol = symbol;
    n.n->missing = 0;
    n.n->children[3].a = NULL;
    child_at(n, 0) = child;
    return n;
}

// The cell of ref, a ref already in head normal form.
static field cell_of(field ref)
{
    return child_at(ref, 0);
}

EXT(Data_DOIORef__newIORef)
{
    field cell = mk_node1(&cell_symbol, child_at(root, 0));
    ext_return(root, mk_node1(&ioref_symbol, cell));
}

// The value can be unevaluated, and other readers may share it, so root
// becomes a forward to it rather than a copy.
EXT(Data_DOIORef__prim_USreadIORef)
{
    GC_ROOT(root);
    field ref = ext_hnf(child_at(root, 0));
    GC_UNROOT(1);
    trail_node(root, false);
    set_forward(root, child_at(cell_of(ref), 0));
}

EXT(Data_DOIORef__prim_USwriteIORef)
{
    GC_ROOT(root);
    field ref = ext_hnf(child_at(root, 0));
    GC_UNROOT(1);
    field cell = cell_of(ref);
    gc_remember(cell.n);
    child_at(cell, 0) = child_at(root, 1);
    ext_return_unit(root);
}
