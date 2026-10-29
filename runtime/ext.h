#ifndef EXT_H
#define EXT_H

/* Helpers for the external functions of library modules.
 *
 * Each module M with externals has its C in ext/M.c (ext/System.IO.c for
 * System.IO), and Rice.Main links it whenever M is part of a program.
 * An external f of module M is the machine code M__f_hnf, with the usual
 * mangling. Most externals are ordinary C, so they're written as
 *
 *     EXT(System_DOIO__prim_UShClose)
 *     {
 *         ...  // root is the call node; its arguments are its children
 *     }
 *
 * which defines the _hnf entry point and has it call the body. The body
 * reads its arguments, does its work, and overwrites root with the result
 * (ext_return and friends). An IO action is the same: evaluating it runs
 * it, and root becomes the action's result.
 *
 * Arguments can be unevaluated, so they're read with ext_int, ext_string
 * and so on, which evaluate them. Those run the machine, which can
 * collect, so a body that reads arguments keeps root in a GC_ROOT, and
 * reads every argument before it allocates anything it keeps.
 */

#include <stdbool.h>
#include <stdio.h>
#include "runtime.h"
#include "Prelude.h"

#define EXT(name)                                              \
    static void name##_body(field root);                       \
    RICE_CC void name##_hnf(union field root, Frame* sp)       \
    {                                                          \
        GC_SAFE_POINT(root, sp);                               \
        rice_root = root;                                      \
        rice_sp = sp;                                          \
        name##_body(root);                                     \
        sp = rice_sp;                                          \
        RETURN();                                              \
    }                                                          \
    static void name##_body(field root)

// Overwrite root with a value we built. These don't depend on a choice,
// so the trail decision gets nondet = false (see ext/Prelude.c).
static inline void ext_return(field root, field value)
{
    trail_node(root, false);
    set_copy(root, value);
}

static inline field ext_mk_int(long n)
{
    return make_Prelude__Int((field)n, 0);
}

static inline field ext_mk_bool(bool b)
{
    return b ? make_Prelude__True(0) : make_Prelude__False(0);
}

static inline void ext_return_unit(field root)
{
    ext_return(root, make_Prelude___LP_RP(0));
}

static inline void ext_return_int(field root, long n)
{
    ext_return(root, ext_mk_int(n));
}

static inline void ext_return_bool(field root, bool b)
{
    ext_return(root, ext_mk_bool(b));
}

static inline void ext_return_string(field root, const char* s)
{
    ext_return(root, toCurryString((char*)s));
}

// Evaluate x to head normal form. Runs the machine.
static inline field ext_hnf(field x)
{
    return settle(x, NULL, eval_hnf);
}

// An Int argument. Runs the machine.
static inline long ext_int(field x)
{
    return child_at_i(ext_hnf(x), 0);
}

// A Char argument. Runs the machine.
static inline char ext_char(field x)
{
    return (char)child_at_c(ext_hnf(x), 0);
}

// A String argument, as a malloc'd C string the caller frees. Runs the
// machine.
static inline char* ext_string(field x)
{
    return toCStr(x);
}

// The tag of a constructor argument (an IOMode, say). Runs the machine.
static inline unsigned char ext_tag(field x)
{
    return ext_hnf(x).n->symbol->tag;
}

// A failed IO operation. Rice has no catch yet, so IO errors end the
// program, with the C library's reason.
void ext_io_error(const char* operation, const char* path, field root);

// An external rice doesn't implement yet.
void ext_unsupported(const char* name, field root);

// System.IO's Handle (ext/System.IO.c). System.IOExts makes them too.
field ext_mk_handle(FILE* f, bool readable, bool writable);
FILE* ext_handle(field h);  // evaluates h; runs the machine

// The program's command line and rice's home, from rice-main.c.
extern int rice_argc;
extern char** rice_argv;
extern const char* rice_install_dir;

#endif
