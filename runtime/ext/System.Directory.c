// The externals of System.Directory (the directory package).

#include <dirent.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include "ext.h"
#include "System/Directory.h"
#include "Data/Time.h"

// Reads an external's one argument, a path, into the C string `path`.
#define PATH_ARG(root, path)                    \
    GC_ROOT(root);                              \
    char* path = ext_string(child_at(root, 0)); \
    GC_UNROOT(1)

EXT(System_DODirectory__prim_USdoesFileExist)
{
    PATH_ARG(root, path);
    struct stat st;
    bool exists = stat(path, &st) == 0 && S_ISREG(st.st_mode);
    free(path);
    ext_return_bool(root, exists);
}

EXT(System_DODirectory__prim_USdoesDirectoryExist)
{
    PATH_ARG(root, path);
    struct stat st;
    bool exists = stat(path, &st) == 0 && S_ISDIR(st.st_mode);
    free(path);
    ext_return_bool(root, exists);
}

EXT(System_DODirectory__prim_USfileSize)
{
    PATH_ARG(root, path);
    struct stat st;
    if(stat(path, &st) != 0)
    {
        ext_io_error("getFileSize", path, root);
    }
    free(path);
    ext_return_int(root, (long)st.st_size);
}

EXT(System_DODirectory__prim_USgetModificationTime)
{
    PATH_ARG(root, path);
    struct stat st;
    if(stat(path, &st) != 0)
    {
        ext_io_error("getModificationTime", path, root);
    }
    free(path);
    ext_return(root, make_Data_DOTime__CTime(ext_mk_int((long)st.st_mtime), 0));
}

EXT(System_DODirectory__getCurrentDirectory)
{
    char buf[PATH_MAX];
    if(getcwd(buf, sizeof buf) == NULL)
    {
        ext_io_error("getCurrentDirectory", ".", root);
    }
    ext_return_string(root, buf);
}

EXT(System_DODirectory__prim_USsetCurrentDirectory)
{
    PATH_ARG(root, path);
    if(chdir(path) != 0)
    {
        ext_io_error("setCurrentDirectory", path, root);
    }
    free(path);
    ext_return_unit(root);
}

// Every entry, "." and ".." included, as GHC's getDirectoryContents does.
EXT(System_DODirectory__prim_USgetDirectoryContents)
{
    PATH_ARG(root, path);
    DIR* d = opendir(path);
    if(d == NULL)
    {
        ext_io_error("getDirectoryContents", path, root);
    }
    free(path);
    // Nothing below runs the machine, so the list needs no GC_ROOT.
    field list = make_Prelude___LB_RB(0);
    struct dirent* e;
    while((e = readdir(d)) != NULL)
    {
        list = make_Prelude___CO(toCurryString(e->d_name), list, 0);
    }
    closedir(d);
    ext_return(root, list);
}

EXT(System_DODirectory__prim_UScreateDirectory)
{
    PATH_ARG(root, path);
    if(mkdir(path, 0777) != 0)
    {
        ext_io_error("createDirectory", path, root);
    }
    free(path);
    ext_return_unit(root);
}

EXT(System_DODirectory__prim_USremoveDirectory)
{
    PATH_ARG(root, path);
    if(rmdir(path) != 0)
    {
        ext_io_error("removeDirectory", path, root);
    }
    free(path);
    ext_return_unit(root);
}

EXT(System_DODirectory__prim_USremoveFile)
{
    PATH_ARG(root, path);
    if(unlink(path) != 0)
    {
        ext_io_error("removeFile", path, root);
    }
    free(path);
    ext_return_unit(root);
}

// renameFile and renameDirectory are both rename(2).
static void rename_body(field root, const char* operation)
{
    GC_ROOT(root);
    char* from = ext_string(child_at(root, 0));
    char* to = ext_string(child_at(root, 1));
    GC_UNROOT(1);
    if(rename(from, to) != 0)
    {
        ext_io_error(operation, from, root);
    }
    free(from);
    free(to);
    ext_return_unit(root);
}

EXT(System_DODirectory__prim_USrenameFile)
{
    rename_body(root, "renameFile");
}

EXT(System_DODirectory__prim_USrenameDirectory)
{
    rename_body(root, "renameDirectory");
}
