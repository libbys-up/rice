// The externals of System.CPUTime.

#include <time.h>
#include "ext.h"
#include "System/CPUTime.h"

// CPU time used so far, in milliseconds.
EXT(System_DOCPUTime__getCPUTime)
{
    ext_return_int(root, (long)(clock() / (CLOCKS_PER_SEC / 1000)));
}

// KiCS2 returns 0 here too.
EXT(System_DOCPUTime__getElapsedTime)
{
    ext_return_int(root, 0);
}
