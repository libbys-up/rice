module Rice.Transform.Unbox (unbox,int',float',char', addBoxes) where

import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies (updTProgTypes, updTProgTExps, tProgName)
import Control.Monad.Trans.State (get, put, State, evalState)
import Data.List (maximum)
import Rice.Util (vars, fresh)

unbox :: TProg -> TProg
unbox p 
 | tProgName p == "Prelude" = fixPrims (updTProgTExps run p)
 | otherwise                = updTProgTExps run p
 where run e = evalState (addBoxes e) (maximum (vars e))
       addBoxTypes ts  = concatMap (\t -> [primType t, boxType t]) [int',float',char'] ++ ts
       removePrimTypes = filter (\(Type q _ _ _) -> unboxedName q `notElem` [int',char',float']) 
       fixPrims        = updTProgTypes (addBoxTypes . removePrimTypes)
       boxType ty = Type (boxedName ty) Public [] 
                         [Cons (boxedName ty) 1 Public [TCons ty []]]
       primType ty = Type ty Public [] []

-- Add boxes to all the literals.
-- Almost everything here is pretty trivial,
-- the only changes we make are to Lit (shockingly) and Case
-- If we have a literal, then we add a constructor for the appropriate type.
-- Example 4 becomes (Int# 4)
--
-- The case expressions are, unsurprisingly, the most complex
-- This is mostly because we have to handle free variables.
-- If I have a constructor case (one where the scrutinee isn't a literal),
-- then I need to make a case to match the box, and an inner case to actually match the value.
-- In the outer case I'm also going to put a bunch of dummy branches
-- to let me know what the possible values are at runtime.
-- This is easiest seen by an example
--
-- case x of
--      1 -> True
--      4 -> True
--      9 -> True
-- would become
-- case x of 
--      Int# x' -> case x' of
--                      1 -> True
--                      4 -> True
--                      9 -> True
--      () -> 1
--      () -> 4
--      () -> 9
--
-- This breaks the typing rules for Curry,
-- but its the easiest way to handle free variables that I've found.
-- Note: I'm using () for readability, but the real patter for the dummy branches is ("","")
-- Which is not a valid pattern in Curry, so it can't be accidentally mapped to anything.

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

-- These should all probably go in Util?
-- We'll see
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

-- get the type name for a raw literal.
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

-- build the nested case structure from the example
-- case x of
--      1 -> True
--      4 -> True
--      9 -> True
-- would become
-- case x of 
--      Int# x' -> case x' of
--                      1 -> True
--                      4 -> True
--                      9 -> True
--      () -> 1
--      () -> 4
--      () -> 9
-- innerCase is the case x' of ...
-- innerBranch is the single branch for the inner case
-- i.e. Int# x' -> case x' of ...
nestCase :: Maybe (TypeExpr,QName) -> CaseType -> TExpr -> [TBranchExpr] -> VState TExpr
nestCase Nothing      ct e bs = return $ TCase ct e bs
nestCase (Just (t,c)) ct e bs = do n <- fresh
                                   let lt = unboxedType t
                                   let innerCase   = TCase ct (TVarE t n) bs
                                   let innerBranch = TBranch (TPattern t (boxedName c) [(n,lt)]) innerCase
                                   return $ TCase ct e (innerBranch : litCases bs)

