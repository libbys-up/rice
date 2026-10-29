module Rice.Transform.Unbox (unbox,int',float',char', addBoxes) where

import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies (updTProgTypes, tProgName)
import Control.Monad.Trans.State (State)
import Rice.Util (fresh, updProgFresh)

unbox :: TProg -> TProg
unbox p
 | tProgName p == "Prelude" = fixPrims (updProgFresh addBoxes p)
 | otherwise                = updProgFresh addBoxes p
 where addBoxTypes ts  = concatMap (\t -> [primType t, boxType t]) [int',float',char'] ++ ts
       removePrimTypes = filter (\(Type q _ _ _) -> unboxedName q `notElem` [int',char',float']) 
       fixPrims        = updTProgTypes (addBoxTypes . removePrimTypes)
       boxType ty = Type (boxedName ty) Public [] 
                         [Cons (boxedName ty) 1 Public [TCons ty []]]
       primType ty = Type ty Public [] []

-- Makes the boxes around Int, Char and Float explicit. The only
-- expressions that change are literals and cases.
--
-- A literal gets a box: `4` becomes `Int 4`, where the `4` inside is a
-- raw Int#.
--
-- A case on a literal becomes a case that takes the box apart, around a
-- case on the raw value:
--
-- case x of                    case x of
--      1 -> True                    Int x' -> case x' of
--      4 -> True       ==>                         1 -> True
--      9 -> True                                   4 -> True
--                                                  9 -> True
--                                   () -> 1
--                                   () -> 4
--                                   () -> 9
--
-- The `() -> n` branches are dummies that list the literals the inner case
-- matches, for narrowing a free variable. They're ill-typed, and their
-- real pattern is the constructor ("",""), which no Curry program can
-- name. See the developer's manual, "Unboxing".

type VState e = State VarIndex e

addBoxes :: TExpr -> VState TExpr
addBoxes v@(TVarE _ _)     = return v
addBoxes (TLit t l)        = return $ TComb t ConsCall (boxCons l) [TLit (litType l) l]
addBoxes (TFree vs e)      = TFree vs <$> addBoxes e
addBoxes (TTyped e t)      = flip TTyped t <$> addBoxes e
addBoxes (TOr e1 e2)       = TOr <$> addBoxes e1 <*> addBoxes e2
addBoxes (TLet vs e)       = TLet <$> mapM boxSnd vs <*> addBoxes e
addBoxes (TComb t ct n es) = TComb t ct n <$> mapM addBoxes es
addBoxes (TCase ct e bs)   = do e'  <- addBoxes e 
                                bs' <- mapM boxBranch bs
                                nestCase (isPrimCase bs) ct e' bs'

-- names for the boxed types
int, char, float :: QName
int   = ("Prelude","Int")
char  = ("Prelude","Char")
float = ("Prelude","Float")

-- names for the unboxed types
int', char', float' :: QName
int'   = ("Prelude","Int#")
char'  = ("Prelude","Char#")
float' = ("Prelude","Float#")

-- get the type name for a raw literal.
litCons :: Literal -> QName
litCons (Intc _)   = int'
litCons (Floatc _) = float'
litCons (Charc _)  = char'

-- get the box's type name for a literal.
boxCons :: Literal -> QName
boxCons (Intc _)   = int
boxCons (Floatc _) = float
boxCons (Charc _)  = char

boxedName :: QName -> QName
boxedName n = case n of
                      ("Prelude","Int#")   -> int
                      ("Prelude","Float#") -> float
                      ("Prelude","Char#")  -> char
                      n -> n

unboxedName :: QName -> QName
unboxedName n = case n of
                      ("Prelude","Int")   -> int'
                      ("Prelude","Float") -> float'
                      ("Prelude","Char")  -> char'
                      n -> n

unboxedType :: TypeExpr -> TypeExpr
unboxedType t = case t of
                     TCons q [] -> TCons (unboxedName q) []
                     _          -> t

-- get the raw type of the literal itself.
litType :: Literal -> TypeExpr
litType l = TCons (litCons l) []

-- get the type of the box for a literal.
boxType :: Literal -> TypeExpr
boxType l = TCons (boxCons l) []

-- box the expression part of the variable binding of a let expression.
boxSnd :: (a,TExpr) -> VState (a,TExpr)
boxSnd (v,e) = (,) v <$> addBoxes e

-- Case expressions

-- check to see if we're actually a case on a primitive value
-- in which case we need to add a new case to take the box off.
isPrimCase :: [TBranchExpr] -> Maybe (TypeExpr, QName)
isPrimCase bs = case bs of
                     (TBranch (TLPattern t l) _: _) -> Just (t, litCons l)
                     _                              -> Nothing

-- get the list of dummy branches so that we can match a free variable.
litCases :: [TBranchExpr] -> [TBranchExpr]
litCases bs = [dummy t l | TBranch (TLPattern t l) _ <- bs]
 where dummy t l = TBranch (TPattern t ("","") []) (TLit (litType l) l) 

-- add boxes to the expression in the branch
-- If We're a literal, then we need to change our type to be an unboxed type.
boxBranch :: TBranchExpr -> VState TBranchExpr
boxBranch (TBranch p@(TPattern _ _ _) e) = TBranch p <$> addBoxes e
boxBranch (TBranch (TLPattern _ l)    e) = TBranch (TLPattern (litType l) l) <$> addBoxes e

-- Builds the nested case from the example at the top of this module.
-- innerCase is `case x' of ...`, and innerBranch is the outer case's real
-- branch, `Int x' -> case x' of ...`.
nestCase :: Maybe (TypeExpr,QName) -> CaseType -> TExpr -> [TBranchExpr] -> VState TExpr
nestCase Nothing      ct e bs = return $ TCase ct e bs
nestCase (Just (t,c)) ct e bs = do n <- fresh
                                   let lt = unboxedType t
                                   let innerCase   = TCase ct (TVarE lt n) bs
                                   let innerBranch = TBranch (TPattern t (boxedName c) [(n,lt)]) innerCase
                                   return $ TCase ct e (innerBranch : litCases bs)

