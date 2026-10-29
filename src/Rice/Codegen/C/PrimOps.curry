------------------------------------------------------------------------------
--- The primitive operations that compile to an inline C expression at
--- every call site instead of a call: the `prim_*` externals of
--- `replace/replace_Prim.curry`. Their arguments are already raw `Int#`,
--- `Char#` or `Float#` values, so the operation is just a C operator or a
--- math library call.
---
--- Each entry says what it computes and the raw type of its result;
--- `primMake` and `primSet` build the expression and statement forms
--- from that.
---
--- An inline primitive runs as soon as control reaches the `let` that
--- binds it, which is only safe because it's pure. So `prim_putChar`
--- isn't here, and neither are the `prim_show*Literal`s (which return a
--- `String`). They're ordinary externals in `runtime/ext/Prelude.c`.
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
data PrimEntry
  = PrimArith { peArgType :: CType, peResType :: CType, peCompute :: [CExpr] -> CExpr }
  | PrimCmp   { peArgType :: CType, peOp :: CExpr -> CExpr -> CExpr }

--- The raw type a primitive's arguments are read as (`ToC.showPrim`).
primArgType :: PrimEntry -> CType
primArgType (PrimArith t _ _) = t
primArgType (PrimCmp   t _)   = t

trueQ, falseQ :: IQName
trueQ  = ("Prelude", "True",  0)
falseQ = ("Prelude", "False", 0)

makeCtor :: IQName -> CExpr
makeCtor n = call ("make_" ++ mangle n) [int 0]

setCtor :: IQName -> CExpr -> CStmt
setCtor n root = scall ("set_" ++ mangle n) [root, int 0]

--- A primitive call as an expression, given its raw arguments.
primMake :: PrimEntry -> [CExpr] -> CExpr
primMake entry args = case entry of
  PrimArith _ resTy compute -> toUnion resTy (compute args)
  PrimCmp   _      op       -> case args of
    [x,y] -> op x y <+> text "?" <+> makeCtor trueQ <+> text ":" <+> makeCtor falseQ
    _     -> error "Rice.Codegen.C.PrimOps: comparison primitive needs exactly 2 arguments"

--- A primitive call that is a function's result: store the result
--- straight into `root`.
primSet :: PrimEntry -> CExpr -> [CExpr] -> [CStmt]
primSet entry root args = case entry of
  PrimArith _ resTy compute -> [rawField resTy root .= compute args]
  PrimCmp   _      op       -> case args of
    [x,y] -> [cifElse (op x y) [setCtor trueQ root] [setCtor falseQ root]]
    _     -> error "Rice.Codegen.C.PrimOps: comparison primitive needs exactly 2 arguments"

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

--- Keyed by module and name. An `IQName` also carries an index that
--- ICurry assigns, which we can't know here.
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
  -- quot and rem truncate toward zero, which is what C's / and % do.
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
  ]

--- The primitive a call refers to, if it's one.
lookupPrim :: IQName -> Maybe PrimEntry
lookupPrim (m,n,_) = Map.lookup (m,n) primOpsTable

------------------------------------------------------------------------------
