#ifndef PRELUDE_EXTERNAL_H
#define PRELUDE_EXTERNAL_H

#include <math.h>
#include "runtime.h"


/////////////////////////////////////////////////////////////////
// Curry: prim_showCharLiteral :: Char# -> String
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USshowCharLiteral(union field c)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USshowCharLiteral(root, );
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USshowCharLiteral(union field root, union field c)
{
    set1(root, &Prelude_prim_USshowCharLiteral_symbol, c);
}

void Prelude_prim_USshowCharLiteral_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_showStringLiteral :: String -> String
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USshowStringLiteral(union field s)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USshowStringLiteral(root, s);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USshowStringLiteral(union field root, union field s)
{
    set1(root, &Prelude_prim_USshowStringLiteral_symbol, s);
}

void Prelude_prim_USshowStringLiteral_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_showIntLiteral :: Int# -> String
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USshowIntLiteral(union field i)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USshowIntLiteral(root, i);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USshowIntLiteral(union field root, union field i)
{
    set1(root, &Prelude_prim_USshowIntLiteral_symbol, i);
}

void Prelude_prim_USshowIntLiteral_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_showFloatLiteral :: Float# -> String
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USshowFloatLiteral(union field f)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USshowFloatLiteral(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USshowFloatLiteral(union field root, union field f)
{
    set1(root, &Prelude_prim_USshowFloatLiteral_symbol, f);
}

void Prelude_prim_USshowFloatLiteral_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_readCharLiteral :: String -> [(Char,String)]
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USreadCharLiteral(union field input)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USreadCharLiteral(root, input);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USreadCharLiteral(union field root, union field input)
{
    set1(root, &Prelude_prim_USreadCharLiteral_symbol, input);
}

void Prelude_prim_USreadCharLiteral_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_readStringLiteral :: String -> [(String,String)]
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USreadStringLiteral(union field input)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USreadStringLiteral(root, input);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USreadStringLiteral(union field root, union field input)
{
    set1(root, &Prelude_prim_USreadStringLiteral_symbol, input);
}

void Prelude_prim_USreadStringLiteral_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_readNatLiteral :: String -> [(Int,String)]
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USreadNatLiteral(union field input)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USreadNatLiteral(root, input);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USreadNatLiteral(union field root, union field input)
{
    set1(root, &Prelude_prim_USreadNatLiteral_symbol, input);
}

void Prelude_prim_USreadNatLiteral_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_readFloatLiteral :: String -> [(Float,String)]
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USreadFloatLiteral(union field input)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USreadFloatLiteral(root, input);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USreadFloatLiteral(union field root, union field input)
{
    set1(root, &Prelude_prim_USreadFloatLiteral_symbol, input);
}

void Prelude_prim_USreadFloatLiteral_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_plusFloat :: Float# -> Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USplusFloat(union field a, union field b)
{
    union field root;
    set_Prelude_prim_USplusFloat(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USplusFloat(union field root, union field a, union field b)
{
    root.f = a.f + b.f;
}

void Prelude_prim_USplusFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_minusFloat :: Float# -> Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USminusFloat(union field a, union field b)
{
    union field root;
    set_Prelude_prim_USminusFloat(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USminusFloat(union field root, union field a, union field b)
{
    root.f = a.f - b.f;
}

void Prelude_prim_USminusFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_timesFloat :: Float# -> Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_UStimesFloat(union field a, union field b)
{
    union field root;
    set_Prelude_prim_UStimesFloat(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_UStimesFloat(union field root, union field a, union field b)
{
    root.f = a.f * b.f;
}

void Prelude_prim_UStimesFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_intToFloat :: Int# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USintToFloat(union field i)
{
    union field root;
    set_Prelude_prim_USintToFloat(root, a);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USintToFloat(union field root, union field i)
{
    root.f = (double)i.i;
}

void Prelude_prim_USintToFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_divFloat :: Float# -> Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USdivFloat(union field a, union field b)
{
    union field root;
    set_Prelude_prim_USdivFloat(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USdivFloat(union field root, union field a, union field b)
{
    root.f = a.f / b.f;
}

void Prelude_prim_USdivFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_truncateFloat :: Float# -> Int#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_UStruncateFloat(union field f)
{
    union field root;
    set_Prelude_prim_UStruncateFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_UStruncateFloat(union field root, union field f)
{
    union field a = a;
    root.i = (long)trunc(f.f);
}

void Prelude_prim_UStruncateFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_roundFloat :: Float# -> Int#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USroundFloat(union field f)
{
    union field root;
    set_Prelude_prim_USroundFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USroundFloat(union field root, union field f)
{
    root.i = (long)llround(f.f);
}

void Prelude_prim_USroundFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_logFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USlogFloat(union field f)
{
    union field root;
    set_Prelude_prim_USlogFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USlogFloat(union field root, union field f)
{
    root.f = log(f.f);
}

void Prelude_prim_USlogFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_expFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USexpFloat(union field f)
{
    union field root;
    set_Prelude_prim_USexpFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USexpFloat(union field root, union field f)
{
    root.f = exp(f.f);
}

void Prelude_prim_USexpFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_sqrtFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USsqrtFloat(union field f)
{
    union field root;
    set_Prelude_prim_USsqrtFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USsqrtFloat(union field root, union field f)
{
    root.f = sqrt(f.f);
}

void Prelude_prim_USsqrtFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_sinFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USsinFloat(union field f)
{
    union field root;
    set_Prelude_prim_USsinFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USsinFloat(union field root, union field f)
{
    root.f = sin(f.f);
}

void Prelude_prim_USsinFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_cosFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_UScosFloat(union field f)
{
    union field root;
    set_Prelude_prim_UScosFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_UScosFloat(union field root, union field f)
{
    root.f = cos(f.f);
}

void Prelude_prim_UScosFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_tanFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_UStanFloat(union field f)
{
    union field root;
    set_Prelude_prim_UStanFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_UStanFloat(union field root, union field f)
{
    root.f = tan(f.f);
}

void Prelude_prim_UStanFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_asinFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USasinFloat(union field f)
{
    union field root;
    set_Prelude_prim_USasinFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USasinFloat(union field root, union field f)
{
    root.f = asin(f.f);
}

void Prelude_prim_USasinFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_acosFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USacosFloat(union field f)
{
    union field root;
    set_Prelude_prim_USacosFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USacosFloat(union field root, union field f)
{
    root.f = acos(f.f);
}

void Prelude_prim_USacosFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_atanFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USatanFloat(union field f)
{
    union field root;
    set_Prelude_prim_USatanFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USatanFloat(union field root, union field f)
{
    root.f = atan(f.f);
}

void Prelude_prim_USatanFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_sinhFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USsinhFloat(union field f)
{
    union field root;
    set_Prelude_prim_USsinhFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USsinhFloat(union field root, union field f)
{
    root.f = sinh(f.f);
}

void Prelude_prim_USsinhFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_coshFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_UScoshFloat(union field f)
{
    union field root;
    set_Prelude_prim_UScoshFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_UScoshFloat(union field root, union field f)
{
    root.f = cosh(f.f);
}

void Prelude_prim_UScoshFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_tanhFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_UStanhFloat(union field f)
{
    union field root;
    set_Prelude_prim_UStanhFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_UStanhFloat(union field root, union field f)
{
    root.f = tanh(f.f);
}

void Prelude_prim_UStanhFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_asinhFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USasinhFloat(union field f)
{
    union field root;
    set_Prelude_prim_USasinhFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USasinhFloat(union field root, union field f)
{
    root.f = asinh(f.f);
}

void Prelude_prim_USasinhFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_acoshFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USacoshFloat(union field f)
{
    union field root;
    set_Prelude_prim_USacoshFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USacoshFloat(union field root, union field f)
{
    root.f = acosh(f.f);
}

void Prelude_prim_USacoshFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_atanhFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USatanhFloat(union field f)
{
    union field root;
    set_Prelude_prim_USatanhFloat(root, f);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USatanhFloat(union field root, union field f)
{
    root.f = atanh(f.f);
}

void Prelude_prim_USatanhFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_ord :: Char# -> Int#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USord(union field c)
{
    union field root;
    set_Prelude_prim_USord(root, c);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USord(union field root, union field c)
{
    root.i = (long)c.c;
}

void Prelude_prim_USord_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_chr :: Int# -> Char#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USchr(union field i)
{
    union field root;
    set_Prelude_prim_USchr(root, i);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USchr(union field root, union field i)
{
    root.c = (unsigned long)i.i;
}

void Prelude_prim_USchr_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: ($!) :: (a -> b) -> a -> b
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_DL_EX(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_DL_EX(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_DL_EX(union field root, union field a, union field b)
{
    set2(root, &Prelude_DL_EX_symbol, a, b);
}

void Prelude_DL_EX_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: ($!!) :: (a -> b) -> a -> b
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_DL_EX_EX(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_DL_EX_EX(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_DL_EX_EX(union field root, union field a, union field b)
{
    set2(root, &Prelude_DL_EX_EX_symbol, a, b);
}

void Prelude_DL_EX_EX_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: ($##) :: (a -> b) -> a -> b
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_DL_HT_HT(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_DL_HT_HT(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_DL_HT_HT(union field root, union field a, union field b)
{
    set2(root, &Prelude_DL_HT_HT_symbol, a, b);
}

void Prelude_DL_HT_HT_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: ensureNotFree :: a -> a
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_ensureNotFree(union field a)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_ensureNotFree(root, a);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_ensureNotFree(union field root, union field a)
{
    set1(root, &Prelude_ensureNotFree_symbol, a);
}

void Prelude_ensureNotFree_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: bindIO :: IO a -> (a -> IO b) -> IO b
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_bindIO(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_bindIO(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_bindIO(union field root, union field a, union field b)
{
    set2(root, &Prelude_bindIO_symbol, a, b);
}

void Prelude_bindIO_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: returnIO :: a -> IO a
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_returnIO(union field a)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_returnIO(root, a);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_returnIO(union field root, union field a)
{
    set1(root, &Prelude_returnIO_symbol, a);
}

void Prelude_returnIO_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: getChar :: IO Char
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_getChar(void)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_getChar(root);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_getChar(union field root)
{
    set0(root, &Prelude_getChar_symbol);
}

void Prelude_getChar_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_putChar :: Char# -> IO ()
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USputChar(union field a)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USputChar(root, a);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USputChar(union field root, union field a)
{
    set1(root, &Prelude_prim_USputChar_symbol, a);
}

void Prelude_prim_USputChar_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_readFile :: String -> IO String
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USreadFile(union field a)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USreadFile(root, a);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USreadFile(union field root, union field a)
{
    set1(root, &Prelude_prim_USreadFile_symbol, a);
}

void Prelude_prim_USreadFile_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_writeFile :: String -> String -> IO ()
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USwriteFile(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USwriteFile(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USwriteFile(union field root, union field a, union field b)
{
    set2(root, &Prelude_prim_USwriteFile_symbol, a, b);
}

void Prelude_prim_USwriteFile_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_appendFile :: String -> String -> IO ()
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USappendFile(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USappendFile(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USappendFile(union field root, union field a, union field b)
{
    set2(root, &Prelude_prim_USappendFile_symbol, a, b);
}

void Prelude_prim_USappendFile_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_ioError :: IOError -> IO a
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USioError(union field a)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USioError(root, a);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USioError(union field root, union field a)
{
    set1(root, &Prelude_prim_USioError_symbol, a);
}

void Prelude_prim_USioError_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: catch :: IO a -> (IOError -> IO a) -> IO a
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_catch(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_catch(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_catch(union field root, union field a, union field b)
{
    set2(root, &Prelude_catch_symbol, a, b);
}

void Prelude_catch_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: constrEq :: a -> a -> Bool
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_constrEq(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_constrEq(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_constrEq(union field root, union field a, union field b)
{
    set2(root, &Prelude_constrEq_symbol, a, b);
}

void Prelude_constrEq_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: (&) :: Bool -> Bool -> Bool
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_AMP(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_AMP(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_AMP(union field root, union field a, union field b)
{
    set2(root, &Prelude_AMP_symbol, a, b);
}

void Prelude_AMP_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: failed :: a
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_failed(void)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_failed(root);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_failed(union field root)
{
    set0(root, &Prelude_failed_symbol);
}

void Prelude_failed_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_error :: String -> a
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USerror(union field a)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USerror(root, a);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USerror(union field root, union field a)
{
    set1(root, &Prelude_prim_USerror_symbol, a);
}

void Prelude_prim_USerror_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: apply :: . (a -> b) -> a -> b
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_apply(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_apply(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_apply(union field root, union field a, union field b)
{
    set2(root, &Prelude_apply_symbol, a, b);
}

void Prelude_apply_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: cond :: Bool -> a -> a
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_cond(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_cond(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_cond(union field root, union field a, union field b)
{
    set2(root, &Prelude_cond_symbol, a, b);
}

void Prelude_cond_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_eqChar :: Char# -> Char# -> Bool
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USeqChar(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USeqChar(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USeqChar(union field root, union field a, union field b)
{
    if(a.c == b.c)
    {
        set_Prelude_True(root);
    }
    else
    {
        set_Prelude_False(root);
    }
}

void Prelude_prim_USeqChar_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_eqInt :: Int# -> Int# -> Bool
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USeqInt(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USeqInt(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USeqInt(union field root, union field a, union field b)
{
    if(a.i == b.i)
    {
        set_Prelude_True(root);
    }
    else
    {
        set_Prelude_False(root);
    }
}

void Prelude_prim_USeqInt_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_eqFloat :: Float# -> Float# -> Bool
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USeqFloat(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USeqFloat(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USeqFloat(union field root, union field a, union field b)
{
    if(a.f == b.f)
    {
        set_Prelude_True(root);
    }
    else
    {
        set_Prelude_False(root);
    }
}

void Prelude_prim_USeqFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_ltEqChar :: Char# -> Char# -> Bool
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USltEqChar(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USltEqChar(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USltEqChar(union field root, union field a, union field b)
{
    if(a.c <= b.c)
    {
        set_Prelude_True(root);
    }
    else
    {
        set_Prelude_False(root);
    }
}

void Prelude_prim_USltEqChar_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_ltEqInt :: Int# -> Int# -> Bool
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USltEqInt(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USltEqInt(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USltEqInt(union field root, union field a, union field b)
{
    if(a.i <= b.i)
    {
        set_Prelude_True(root);
    }
    else
    {
        set_Prelude_False(root);
    }
}

void Prelude_prim_USltEqInt_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_ltEqFloat :: Float# -> Float# -> Bool
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USltEqFloat(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_prim_USltEqFloat(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USltEqFloat(union field root, union field a, union field b)
{
    if(a.f <= b.f)
    {
        set_Prelude_True(root);
    }
    else
    {
        set_Prelude_False(root);
    }
}

void Prelude_prim_USltEqFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_plusInt :: Int# -> Int# -> Int#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USplusInt(union field a, union field b)
{
    union field root;
    set_Prelude_prim_USplusInt(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USplusInt(union field root, union field a, union field b)
{
    root.i = a.i + b.i;
}

void Prelude_prim_USplusInt_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_minusInt :: Int# -> Int# -> Int#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USminusInt(union field a, union field b)
{
    union field root;
    set_Prelude_prim_USminusInt(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USminusInt(union field root, union field a, union field b)
{
    root.i = a.i - b.i;
}

void Prelude_prim_USminusInt_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_timesInt :: Int# -> Int# -> Int#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_UStimesInt(union field a, union field b)
{
    union field root;
    set_Prelude_prim_UStimesInt(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_UStimesInt(union field root, union field a, union field b)
{
    root.i = a.i * b.i;
}

void Prelude_prim_UStimesInt_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_negateFloat :: Float# -> Float#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USnegateFloat(union field a)
{
    union field root;
    set_Prelude_prim_USnegateFloat(root, a);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USnegateFloat(union field root, union field a)
{
    root.f = -a.f;
}

void Prelude_prim_USnegateFloat_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_divInt :: Int# -> Int# -> Int#
/////////////////////////////////////////////////////////////////

// We need functions for mod and div, because they
// don't behave exaclty the same as C's % and / with negative numbers
static inline __attribute__((always_inline))
long haskell_mod(long a, long b)
{
    int r = a % b;

    // If remainder has a different sign than divisor, adjust it
    if (r != 0 && ((r < 0 && b > 0) || (r > 0 && b < 0)))
    {
        r += b;
    }

    return r;
}

static inline __attribute__((always_inline))
long haskell_div(long a, long b)
{
    return (a - my_mod(a,b)) / b;
}

static inline __attribute__((always_inline))
union field make_Prelude_prim_USdivInt(union field a, union field b)
{
    union field root;
    set_Prelude_prim_USdivInt(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USdivInt(union field root, union field a, union field b)
{
    root.i = haskell_div(a.i, b.i);
}

void Prelude_prim_USdivInt_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_modInt :: Int# -> Int# -> Int#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USmodInt(union field a, union field b)
{
    union field root;
    set_Prelude_prim_USmodInt(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USmodInt(union field root, union field a, union field b)
{
    root.i = haskell_mod(a.i, b.i); 
}

void Prelude_prim_USmodInt_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_quotInt :: Int# -> Int# -> Int#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USquotInt(union field a, union field b)
{
    union field root;
    set_Prelude_prim_USquotInt(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USquotInt(union field root, union field a, union field b)
{
    root.i = a.i / b.i;
}

void Prelude_prim_USquotInt_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: prim_remInt :: Int# -> Int# -> Int#
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_prim_USremInt(union field a, union field b)
{
    union field root;
    set_Prelude_prim_USremInt(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_prim_USremInt(union field root, union field a, union field b)
{
    root.i = a.i % b.i;
}

void Prelude_prim_USremInt_hnf(union field root);

/////////////////////////////////////////////////////////////////
// Curry: nonstrictEq :: a -> a -> Bool
/////////////////////////////////////////////////////////////////

static inline __attribute__((always_inline))
union field make_Prelude_nonstrictEq(union field a, union field b)
{
    union field root;
    root.n = (Node *)alloc(sizeof(Node));
    set_Prelude_nonstrictEq(root, a, b);
    return root;
}

static inline __attribute__((always_inline))
void set_Prelude_nonstrictEq(union field root, union field a, union field b)
{
    set2(root, &Prelude_nonstrictEq_symbol, a, b);
}

void Prelude_nonstrictEq_hnf(union field root);

#endif // PRELUDE_EXTERNAL_H
