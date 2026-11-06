// The externals of ReadShowTerm (the read-legacy package).
//
// Showing and reading any term by its constructors' names needs a table
// of every constructor in the program, which rice doesn't build yet.
// Rice itself only reaches these through FlatCurry.Files and ICurry.Files,
// which it doesn't call.

#include "ext.h"
#include "ReadShowTerm.h"

EXT(ReadShowTerm__prim_USshowTerm)
{
    ext_unsupported("ReadShowTerm.showTerm", root);
}

EXT(ReadShowTerm__prim_USreadsUnqualifiedTerm)
{
    ext_unsupported("ReadShowTerm.readsUnqualifiedTerm", root);
}
