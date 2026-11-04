// What ext.h declares for every module's externals.
// rice_install_dir is defined in each program's generated rice-main.c,
// since it's different for each program.

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ext.h"

// The command line, for System.Environment. The generated rice-main.c sets
// them.
int rice_argc = 0;
char** rice_argv = NULL;

void ext_io_error(const char* operation, const char* path, field root)
{
    const char* reason = strerror(errno);
    size_t len = strlen(operation) + strlen(path) + strlen(reason) + 8;
    char* msg = malloc(len);
    snprintf(msg, len, "%s: %s: %s", operation, path, reason);
    error(msg, root);
}

void ext_unsupported(const char* name, field root)
{
    size_t len = strlen(name) + 40;
    char* msg = malloc(len);
    snprintf(msg, len, "%s isn't implemented in rice yet", name);
    error(msg, root);
}
