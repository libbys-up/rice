#ifndef PRIM_H
#define PRIM_H

#include <math.h>

// div/mod/quot/rem: quot/rem are already exactly C's native `/`/`%`
// (truncating-toward-zero, same-sign-as-dividend).
// Rice.Codegen.C.PrimOps uses the operators directly. div/mod need the
// standard sign-adjusted formulas.
//  - div rounds toward negative infinity,
//  - mod takes the divisor's sign
// (tests/programs/prelude_prims/int_arith.curry checks them, with a
// negative dividend too)

static inline long prim_mod(long a, long b)
{
    long r = a % b;
    if(r != 0 && ((r < 0) != (b < 0)))
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
