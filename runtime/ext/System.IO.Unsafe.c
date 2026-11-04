// The externals of System.IO.Unsafe.
//
// Only unsafePerformIO is external in rice. The term-inspection functions
// (isVar, isGround, showAnyTerm, ...) stop with "not yet implemented"
// (lib/System/IO/Unsafe.curry, under __RICE__).

#include "ext.h"
#include "System/IO/Unsafe.h"

// unsafePerformIO act becomes act >>= return, so the action runs the way
// any other does: bindIO runs a fresh copy of it, so an action shared with
// other code still runs there too (ext/Prelude.c), and commits to the
// choices it made. The rewrite is deterministic.
RICE_CC void System_DOIO_DOUnsafe__unsafePerformIO_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    field none = { .n = NULL };
    field ret = make_Prelude__returnIO(none, 1);
    trail_node(root, false);
    set_Prelude__bindIO(root, child_at(root, 0), ret, 0);
    MUSTTAIL return Prelude__bindIO_hnf(root, sp);
}
