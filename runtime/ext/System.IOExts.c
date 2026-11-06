// The externals of System.IOExts (the io-extra package).
//
// Running a command with pipes to it isn't implemented yet. Rice itself
// doesn't use these.

#include "ext.h"
#include "System/IOExts.h"

EXT(System_DOIOExts__prim_USexecCmd)
{
    ext_unsupported("System.IOExts.execCmd", root);
}

EXT(System_DOIOExts__prim_USevalCmd)
{
    ext_unsupported("System.IOExts.evalCmd", root);
}

EXT(System_DOIOExts__prim_USconnectToCmd)
{
    ext_unsupported("System.IOExts.connectToCommand", root);
}
