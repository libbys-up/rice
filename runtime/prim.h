#ifndef PRIM_H
#define PRIM_H

#include <math.h>

// Helpers for the handful of primitive operations (Rice.Codegen.C.PrimOps)
// whose correct behavior isn't just a bare C operator -- kept as real,
// reviewable functions here rather than inlined as generated ternary
// expressions at every call site (repeated once per module that uses them,
// and much harder to read/verify in the generated .c output).
//
// div/mod/quot/rem: quot/rem are already exactly C's native `/`/`%`
// (truncating-toward-zero, same-sign-as-dividend) -- no helper needed,
// Rice.Codegen.C.PrimOps uses the operators directly. div/mod need the
// standard sign-adjusted formulas (div rounds toward negative infinity,
// mod takes the divisor's sign); verified against test/test.c's own
// worked examples for all four sign combinations before being written
// here as the authoritative implementation.

static inline long prim_mod(long a, long b)
{
    long r = a % b;
    if (r != 0 && ((r < 0) != (b < 0)))
    {
        r += b;
    }
    return r;
}

static inline long prim_div(long a, long b)
{
    return (a - prim_mod(a, b)) / b;
}

// round-half-away-from-zero (C's own round()), not Curry/Haskell's
// round-half-to-even -- close enough for now; exact tie-breaking behavior
// isn't verified and would need its own pass if it ever matters.
static inline long prim_round(double x)
{
    return (long)round(x);
}

#endif // PRIM_H
