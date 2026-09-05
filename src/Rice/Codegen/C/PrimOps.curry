------------------------------------------------------------------------------
--- The table of primitive operations (`replace/replace_Prim.curry`'s
--- `prim_*` externals) that get compiled to an inline C expression at every
--- call site, instead of an actual function call -- these are the
--- unboxed-argument, unboxed-result primitives `Rice.Transform.Unbox`'s
--- design assumes exist (see `archetecture.md`'s Unboxing section): by the
--- time one of these is called, its arguments are already raw `field`
--- members (an already-unboxed `Int#`/`Char#`/`Float#`), never a boxed
--- node, so there's never a reason to pay for an actual C function call --
--- reading `field .= <op>;` (or `(field)(cast)(<op>)` in expression
--- position) is the whole function body.
---
--- Confirmed against the *real* names Rice actually generates (not
--- old_rice's or fast_backtrack's assumed `primAddInt`-style names, both
--- of which predate `replace_Prim.curry`'s current naming) by compiling a
--- small test program and reading its `--icurry` output directly.
---
--- Each entry only needs to say what it computes and which raw type its
--- result belongs to; `primMake`/`primSet` below derive both the
--- expression form and the statement form from that one description --
--- see `src/codegen-runtime-review.md`'s case for this over old_rice's
--- ~15 independently hand-written `make`/`set` pairs.
---
--- Deliberately **not** in this table: `prim_show*Literal` -- those return
--- a `String` (not a raw scalar), and are already hand-written `_hnf`
--- functions in `runtime/external.c`/`Prelude_external.c`, dispatched the
--- ordinary way (an `IExternal` function, not inlined).
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Codegen.C.PrimOps (PrimEntry(..), lookupPrim, primArgType, primMake, primSet) where

import qualified Data.Map as Map
import Text.Pretty

import ICurry.Types (IQName)
import Rice.Codegen.Names (mangle)
import Rice.Codegen.C.C

--- One primitive's C compilation strategy.
--- @cons PrimArith  a value-computing primitive (`prim_plusInt`, `prim_ord`,
---                   ...): reads `primArgType`-typed raw arguments, computes
---                   `peCompute args`, and the result belongs in
---                   `peResType` (usually the same as `primArgType`, but not
---                   always -- `prim_ord`/`prim_chr`/`prim_intToFloat`/
---                   `prim_truncateFloat`/`prim_roundFloat` all cross types).
--- @cons PrimCmp     a comparison (`prim_eqInt`, `prim_ltEqChar`, ...):
---                    reads `primArgType`-typed raw arguments, produces a
---                    `Prelude.True`/`Prelude.False` node, not a raw value.
--- @cons PrimPutChar `prim_putChar` specifically: side-effecting, produces
---                    `Prelude.()`, not a raw value -- the one primitive
---                    that doesn't fit either shape above.
data PrimEntry
  = PrimArith { peArgType :: CType, peResType :: CType, peCompute :: [CExpr] -> CExpr }
  | PrimCmp   { peArgType :: CType, peOp :: CExpr -> CExpr -> CExpr }
  | PrimPutChar

--- Which raw type a primitive's arguments should be read as (needed by
--- the caller to project each `IExpr` argument via `showPrim` before
--- `primMake`/`primSet` ever sees it).
primArgType :: PrimEntry -> CType
primArgType (PrimArith t _ _) = t
primArgType (PrimCmp   t _)   = t
primArgType PrimPutChar       = "char"

trueQ, falseQ, unitQ :: IQName
trueQ  = ("Prelude", "True",  0)
falseQ = ("Prelude", "False", 0)
unitQ  = ("Prelude", "()",    0)

makeCtor :: IQName -> CExpr
makeCtor n = call ("make_" ++ mangle n) [int 0]

setCtor :: IQName -> CExpr -> CStmt
setCtor n root = scall ("set_" ++ mangle n) [root, int 0]

--- The full expression for a primitive call, given its already-projected
--- (`showPrim`) arguments -- used wherever the call appears as an
--- expression (`showExpr`).
primMake :: PrimEntry -> [CExpr] -> CExpr
primMake entry args = case entry of
  PrimArith _ resTy compute -> toUnion resTy (compute args)
  PrimCmp   _      op       -> case args of
    [x,y] -> op x y <+> text "?" <+> makeCtor trueQ <+> text ":" <+> makeCtor falseQ
    _     -> error "Rice.Codegen.C.PrimOps: comparison primitive needs exactly 2 arguments"
  -- Side-effecting primitives can still appear in expression position
  -- (Prelude's own code does, confirmed empirically -- not just the
  -- `Let`-bound `setExpr` position this was first assumed to be
  -- restricted to). C's comma operator sequences the side effect and
  -- yields the Unit value.
  PrimPutChar -> case args of
    [c] -> parens (call "putchar" [c] <> comma <+> makeCtor unitQ)
    _   -> error "Rice.Codegen.C.PrimOps: prim_putChar needs exactly 1 argument"

--- The statement form: assign the primitive's result directly into
--- `root`'s raw field -- used wherever the call is the immediate
--- right-hand side of a `Let` (`setExpr`), avoiding the allocation
--- `primMake`'s standalone expression form would otherwise need.
primSet :: PrimEntry -> CExpr -> [CExpr] -> [CStmt]
primSet entry root args = case entry of
  PrimArith _ resTy compute -> [rawField resTy root .= compute args]
  PrimCmp   _      op       -> case args of
    [x,y] -> [cifElse (op x y) [setCtor trueQ root] [setCtor falseQ root]]
    _     -> error "Rice.Codegen.C.PrimOps: comparison primitive needs exactly 2 arguments"
  PrimPutChar -> case args of
    [c] -> [scall "putchar" [c], setCtor unitQ root]
    _   -> error "Rice.Codegen.C.PrimOps: prim_putChar needs exactly 1 argument"

arith :: CType -> CType -> ([CExpr] -> CExpr) -> PrimEntry
arith argTy resTy f = PrimArith argTy resTy f

cmp :: CType -> (CExpr -> CExpr -> CExpr) -> PrimEntry
cmp argTy op = PrimCmp argTy op

un :: (CExpr -> CExpr) -> [CExpr] -> CExpr
un f args = case args of
  [x] -> f x
  _   -> error "Rice.Codegen.C.PrimOps: unary primitive needs exactly 1 argument"

bin :: (CExpr -> CExpr -> CExpr) -> [CExpr] -> CExpr
bin f args = case args of
  [x,y] -> f x y
  _     -> error "Rice.Codegen.C.PrimOps: binary primitive needs exactly 2 arguments"

libCall :: CName -> [CExpr] -> CExpr
libCall = call

--- Keyed by (module, name) only, *not* the full `IQName` triple: ICurry's
--- third component is a per-module function-numbering index assigned at
--- ICurry-generation time (see `ICurry.Types`' own doc comment on
--- `IQName`), not something this table can predict or should depend on --
--- matching on it would make every lookup here silently miss. A
--- primitive's true identity is (module, name); the index is incidental.
primOpsTable :: Map.Map (String,String) PrimEntry
primOpsTable = Map.fromList
  [ -- comparisons
    (("Prelude","prim_eqChar"),    cmp "char"  (.==))
  , (("Prelude","prim_eqInt"),     cmp "int"   (.==))
  , (("Prelude","prim_eqFloat"),   cmp "float" (.==))
  , (("Prelude","prim_ltEqChar"),  cmp "char"  (.<=))
  , (("Prelude","prim_ltEqInt"),   cmp "int"   (.<=))
  , (("Prelude","prim_ltEqFloat"), cmp "float" (.<=))

    -- Int arithmetic
  , (("Prelude","prim_plusInt"),  arith "int" "int" (bin (.+)))
  , (("Prelude","prim_minusInt"), arith "int" "int" (bin (.-)))
  , (("Prelude","prim_timesInt"), arith "int" "int" (bin (.*)))
  , (("Prelude","prim_divInt"),   arith "int" "int" (bin (\x y -> libCall "prim_div" [x,y])))
  , (("Prelude","prim_modInt"),   arith "int" "int" (bin (\x y -> libCall "prim_mod" [x,y])))
  -- quot/rem are already exactly C's native `/`/`%` (truncating toward
  -- zero, same sign as the dividend) -- see runtime/prim.h's comment.
  , (("Prelude","prim_quotInt"),  arith "int" "int" (bin (./)))
  , (("Prelude","prim_remInt"),   arith "int" "int" (bin (.%)))

    -- Float arithmetic
  , (("Prelude","prim_plusFloat"),   arith "float" "float" (bin (.+)))
  , (("Prelude","prim_minusFloat"),  arith "float" "float" (bin (.-)))
  , (("Prelude","prim_timesFloat"),  arith "float" "float" (bin (.*)))
  , (("Prelude","prim_divFloat"),    arith "float" "float" (bin (./)))
  , (("Prelude","prim_negateFloat"), arith "float" "float" (un (\x -> text "-" <> x)))

    -- conversions (cross type -- arg and result differ)
  , (("Prelude","prim_ord"),           arith "char"  "int"   (un id))
  , (("Prelude","prim_chr"),           arith "int"   "char"  (un id))
  , (("Prelude","prim_intToFloat"),    arith "int"   "float" (un id))
  , (("Prelude","prim_truncateFloat"), arith "float" "int"   (un (\x -> parens (text "long") <> x)))
  , (("Prelude","prim_roundFloat"),    arith "float" "int"   (un (\x -> libCall "prim_round" [x])))

    -- transcendental Float functions -- straight C math library calls
  , (("Prelude","prim_logFloat"),   arith "float" "float" (un (\x -> libCall "log"  [x])))
  , (("Prelude","prim_expFloat"),   arith "float" "float" (un (\x -> libCall "exp"  [x])))
  , (("Prelude","prim_sqrtFloat"),  arith "float" "float" (un (\x -> libCall "sqrt" [x])))
  , (("Prelude","prim_sinFloat"),   arith "float" "float" (un (\x -> libCall "sin"  [x])))
  , (("Prelude","prim_cosFloat"),   arith "float" "float" (un (\x -> libCall "cos"  [x])))
  , (("Prelude","prim_tanFloat"),   arith "float" "float" (un (\x -> libCall "tan"  [x])))
  , (("Prelude","prim_asinFloat"),  arith "float" "float" (un (\x -> libCall "asin" [x])))
  , (("Prelude","prim_acosFloat"),  arith "float" "float" (un (\x -> libCall "acos" [x])))
  , (("Prelude","prim_atanFloat"),  arith "float" "float" (un (\x -> libCall "atan" [x])))
  , (("Prelude","prim_sinhFloat"),  arith "float" "float" (un (\x -> libCall "sinh" [x])))
  , (("Prelude","prim_coshFloat"),  arith "float" "float" (un (\x -> libCall "cosh" [x])))
  , (("Prelude","prim_tanhFloat"),  arith "float" "float" (un (\x -> libCall "tanh" [x])))
  , (("Prelude","prim_asinhFloat"), arith "float" "float" (un (\x -> libCall "asinh" [x])))
  , (("Prelude","prim_acoshFloat"), arith "float" "float" (un (\x -> libCall "acosh" [x])))
  , (("Prelude","prim_atanhFloat"), arith "float" "float" (un (\x -> libCall "atanh" [x])))

    -- I/O
  , (("Prelude","prim_putChar"), PrimPutChar)
  ]

--- Look up a call site's `IQName` against the primitive table -- see
--- `primOpsTable`'s own comment on why this drops the index.
lookupPrim :: IQName -> Maybe PrimEntry
lookupPrim (m,n,_) = Map.lookup (m,n) primOpsTable

------------------------------------------------------------------------------
