// The externals of System.Environment.

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "ext.h"
#include "System/Environment.h"

// The arguments after the program name.
EXT(System_DOEnvironment__getArgs)
{
    field list = make_Prelude___LB_RB(0);
    for(int i = rice_argc - 1; i >= 1; i--)
    {
        list = make_Prelude___CO(toCurryString(rice_argv[i]), list, 0);
    }
    ext_return(root, list);
}

// An unset variable is "".
EXT(System_DOEnvironment__prim_USgetEnviron)
{
    GC_ROOT(root);
    char* name = ext_string(child_at(root, 0));
    GC_UNROOT(1);
    const char* value = getenv(name);
    free(name);
    ext_return_string(root, value == NULL ? "" : value);
}

EXT(System_DOEnvironment__prim_USsetEnviron)
{
    GC_ROOT(root);
    char* name = ext_string(child_at(root, 0));
    char* value = ext_string(child_at(root, 1));
    GC_UNROOT(1);
    setenv(name, value, 1);
    free(name);
    free(value);
    ext_return_unit(root);
}

EXT(System_DOEnvironment__prim_USunsetEnviron)
{
    GC_ROOT(root);
    char* name = ext_string(child_at(root, 0));
    GC_UNROOT(1);
    unsetenv(name);
    free(name);
    ext_return_unit(root);
}

EXT(System_DOEnvironment__getHostname)
{
    char buf[256];
    if(gethostname(buf, sizeof buf) != 0)
    {
        ext_io_error("getHostname", "", root);
    }
    buf[sizeof buf - 1] = '\0';
    ext_return_string(root, buf);
}

// The program's file name, without its directory.
EXT(System_DOEnvironment__getProgName)
{
    const char* name = rice_argc > 0 ? rice_argv[0] : "";
    const char* slash = strrchr(name, '/');
    ext_return_string(root, slash == NULL ? name : slash + 1);
}

EXT(System_DOEnvironment__isWindows)
{
    ext_return_bool(root, false);
}
