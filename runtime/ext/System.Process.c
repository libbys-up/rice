// The externals of System.Process (the process package).

#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
#include "ext.h"
#include "System/Process.h"

EXT(System_DOProcess__getPID)
{
    ext_return_int(root, (long)getpid());
}

// The command's exit code, as a shell reports it: 128 + n if a signal n
// ended it.
EXT(System_DOProcess__prim_USsystem)
{
    GC_ROOT(root);
    char* cmd = ext_string(child_at(root, 0));
    GC_UNROOT(1);
    // The command's output goes after ours.
    fflush(stdout);
    fflush(stderr);
    int status = system(cmd);
    free(cmd);
    long code = status == -1        ? -1
              : WIFEXITED(status)   ? WEXITSTATUS(status)
              : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
              : status;
    ext_return_int(root, code);
}

EXT(System_DOProcess__prim_USexitWith)
{
    GC_ROOT(root);
    long code = ext_int(child_at(root, 0));
    GC_UNROOT(1);
    fflush(stdout);
    exit((int)code);
}

EXT(System_DOProcess__prim_USsleep)
{
    GC_ROOT(root);
    long secs = ext_int(child_at(root, 0));
    GC_UNROOT(1);
    sleep((unsigned int)secs);
    ext_return_unit(root);
}
