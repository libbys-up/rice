------------------------------------------------------------------------------
--- A table of facts about each function (size, parameters, body, whether
--- it's a loop breaker) that the optimizer uses to decide whether to
--- inline a call.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Optimize.FunTable
  ( FunTable, makeFunTable
  , arity, params, body, freshVar, isLoopBreaker
  , inlinable, simple
 ) where

import qualified Data.Map as Map
import Data.List (sum)

import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies (isExternal, tFuncArgs, tFuncBody, tFuncName
                                , tFuncArity, tBranchTExpr)

import FlatCurry.Transform.Typed.Utils (newVar)

------------------------------------------------------------------------------

--- The size (in AST nodes) above which a function is never considered
--- for inlining.
sizeLimit :: Int
sizeLimit = 35

data FunInfo = FunInfo
  { fiExternal :: Bool
  , fiLoopBrk  :: Bool
  , fiCaseless :: Bool         -- no Case anywhere in the body; feeds `simple`
  , fiArity    :: Int
  , fiParams   :: [VarIndex]
  , fiFreshVar :: VarIndex
  , fiSize     :: Int
  , fiBody     :: TExpr
  }

type FunTable = Map.Map QName FunInfo

--- Builds a table from a module's functions, given the loop breakers,
--- which must never be inlined (`Rice.Transform.Order.orderFuns`).
makeFunTable :: [QName] -> [TFuncDecl] -> FunTable
makeFunTable loopBreakers = foldr (addEntry loopBreakers) Map.empty

addEntry :: [QName] -> TFuncDecl -> FunTable -> FunTable
addEntry loopBreakers f tab = Map.insert (tFuncName f) entry tab
 where
  entry
   | isExternal f = FunInfo True True False (tFuncArity f) [] 0
                             (sizeLimit + 1) noExternalBody
   | otherwise    = FunInfo False isBreaker (isCaseless b) (tFuncArity f)
                             ps freshV (getSize b) b

  -- Never read: `inlinable` and `simple` are false for an external.
  noExternalBody = error "FunTable: no body for an external function"

  isBreaker = tFuncName f `elem` loopBreakers
  ps        = map fst (tFuncArgs f)
  b         = tFuncBody f
  freshV    = max (1 + foldr max 0 ps) (newVar b)

------------------------------------------------------------------------------

getSize :: TExpr -> Int
getSize (TVarE _ _)      = 1
getSize (TLit _ _)       = 1
getSize (TComb _ _ _ es) = 1 + sum (map getSize es)
getSize (TFree _ e)      = getSize e + 1
getSize (TOr e1 e2)      = getSize e1 + getSize e2
getSize (TTyped e _)     = getSize e
getSize (TLet bs e)      = sum (map (getSize . snd) bs) + getSize e + 1
getSize (TCase _ e bs)   = 1 + getSize e + sum (map (getSize . tBranchTExpr) bs)

isCaseless :: TExpr -> Bool
isCaseless (TVarE _ _)      = True
isCaseless (TLit _ _)       = True
isCaseless (TComb _ _ _ es) = all isCaseless es
isCaseless (TFree _ e)      = isCaseless e
isCaseless (TOr e1 e2)      = all isCaseless [e1,e2]
isCaseless (TTyped e _)     = isCaseless e
isCaseless (TLet bs e)      = all isCaseless (e : map snd bs)
isCaseless (TCase _ _ _)    = False

------------------------------------------------------------------------------
-- Queries

lookupFI :: FunTable -> QName -> Maybe FunInfo
lookupFI ft n = Map.lookup n ft

arity :: FunTable -> QName -> Int
arity ft n = maybe 0 fiArity (lookupFI ft n)

params :: FunTable -> QName -> [VarIndex]
params ft n = maybe [] fiParams (lookupFI ft n)

body :: FunTable -> QName -> TExpr
body ft n = maybe (error notFound) fiBody (lookupFI ft n)
 where notFound = "FunTable.body: unknown function " ++ show n

freshVar :: FunTable -> QName -> VarIndex
freshVar ft n = maybe 0 fiFreshVar (lookupFI ft n)

isLoopBreaker :: FunTable -> QName -> Bool
isLoopBreaker ft n = maybe False fiLoopBrk (lookupFI ft n)

--- Is a saturated call to this function safe and worth inlining? It has
--- to be defined here (not external), not a loop breaker, and small.
inlinable :: FunTable -> QName -> Bool
inlinable ft n = case lookupFI ft n of
  Nothing -> False
  Just fi -> not (fiExternal fi || fiLoopBrk fi) && fiSize fi < sizeLimit

--- Inlinable, very small, and without a case, so inlining it can't add
--- branches to the caller.
simple :: FunTable -> QName -> Bool
simple ft n = case lookupFI ft n of
  Nothing -> False
  Just fi -> fiCaseless fi && fiSize fi < 10 && inlinable ft n

------------------------------------------------------------------------------
