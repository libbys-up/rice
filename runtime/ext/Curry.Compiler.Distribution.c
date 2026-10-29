// The externals of Curry.Compiler.Distribution: which Curry system this
// program was compiled with.
//
// The version is package.json's, and the base version is lib/VERSION's.
// Update them here along with those.

#include "ext.h"
#include "Curry/Compiler/Distribution.h"

EXT(Curry_DOCompiler_DODistribution__curryCompiler)
{
    ext_return_string(root, "rice");
}

EXT(Curry_DOCompiler_DODistribution__curryCompilerMajorVersion)
{
    ext_return_int(root, 1);
}

EXT(Curry_DOCompiler_DODistribution__curryCompilerMinorVersion)
{
    ext_return_int(root, 0);
}

EXT(Curry_DOCompiler_DODistribution__curryCompilerRevisionVersion)
{
    ext_return_int(root, 0);
}

// Programs run as native code, so the runtime is rice's own.
EXT(Curry_DOCompiler_DODistribution__curryRuntime)
{
    ext_return_string(root, "rice");
}

EXT(Curry_DOCompiler_DODistribution__curryRuntimeMajorVersion)
{
    ext_return_int(root, 1);
}

EXT(Curry_DOCompiler_DODistribution__curryRuntimeMinorVersion)
{
    ext_return_int(root, 0);
}

EXT(Curry_DOCompiler_DODistribution__baseVersion)
{
    ext_return_string(root, "3.4.0");
}

// rice's home when the program was compiled (rice-main.c).
EXT(Curry_DOCompiler_DODistribution__installDir)
{
    ext_return_string(root, rice_install_dir);
}
