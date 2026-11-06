------------------------------------------------------------------------------
--- Implementation of transforming TypedFlatCurry expressions by applying
--- deterministically defined expression transformations as long as
--- possible.
---
--- This is the typed (`TExpr`) counterpart of `FlatCurry.Transform.ExecDet`
--- from the `flatcurry-transform` package (see `FlatCurry.Transform.Typed.
--- Types` for why this lives under `FlatCurry/Transform/Typed`).
---
--- @author Steven Libby
------------------------------------------------------------------------------

module FlatCurry.Transform.Typed.ExecDet
  ( transformFuncsInProgDet, transformRuleDet
  , transformExprDet, transformExprMaxDet, showTransformExprDet
  , showTransformRuleDet
 ) where

import Data.Tuple.Extra        ( second )
import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies ( updTProgTFuncs, updTFuncTRule )

import FlatCurry.Transform.Typed.Types
import FlatCurry.Transform.Typed.Utils ( ReWriter(..)
                                        , curVar, newVar, replace, update )

-- Only used for the debug trace in showTransformExprDet/showTransSteps.
-- FlatCurry.Typed.Pretty (from the flatcurry-typed package) has no
-- expression-level pretty-printer, so this borrows Rice's own fix for
-- that gap. If this module migrates into flatcurry-transform, that
-- pretty-printer needs to move (or get replaced) with it.
import FlatCurry.Typed.PrettyFixed ( ppExp )
import Text.Pretty                 ( pPrint )

------------------------------------------------------------------------------
--- Transforms the bodies of all functions in a TypedFlatCurry program
--- according to some deterministic(!) expression transformation provided
--- as the first argument.
transformFuncsInProgDet :: TExprTransformationDet -> TProg -> TProg
transformFuncsInProgDet trans =
  updTProgTFuncs (map (updTFuncTRule (transformRuleDet trans)))

--- Transforms the body of a function's rule. New variables are numbered
--- above the parameters too, not just the body: a parameter the body never
--- uses still has its number.
transformRuleDet :: TExprTransformationDet -> TRule -> TRule
transformRuleDet trans rule = case rule of
  TRule ps e    -> TRule ps (fst (runTrExpr trans (-1) (ruleNewVar ps e) e))
  TExternal _ _ -> rule

--- The first variable index that's free in a rule with parameters `ps`
--- and body `e`.
ruleNewVar :: [(VarIndex, TypeExpr)] -> TExpr -> VarIndex
ruleNewVar ps e = foldr (max . (+ 1) . fst) (newVar e) ps

--- Transforms an expression by applying some deterministic(!) expression
--- transformation as long as possible with a bottom-up strategy.
transformExprDet :: TExprTransformationDet -> TExpr -> TExpr
transformExprDet = transformExprMaxDet (-1)

--- The same as `transformExprDet` but takes the maximum number of
--- transformation steps to be applied as a further argument. If the
--- number is negative, then keep going until no transformation can be
--- applied.
transformExprMaxDet :: Int -> TExprTransformationDet -> TExpr -> TExpr
transformExprMaxDet n trans e = fst (runTrExpr trans n (newVar e) e)

--- The same as `transformExprMaxDet` but also returns a formatted trace
--- of all applied transformation steps, and its total number.
showTransformExprDet :: Int -> TExprTransformationDet
                     -> TExpr -> (TExpr, String, Int)
showTransformExprDet n trans e
  = let (e', steps) = runTrExpr trans n (newVar e) e
    in (e', showTransSteps e steps, length steps)

--- `showTransformExprDet` for a rule with parameters `ps` and body `e`,
--- numbering new variables the same way `transformRuleDet` does.
showTransformRuleDet :: Int -> TExprTransformationDet
                     -> [(VarIndex, TypeExpr)] -> TExpr -> (TExpr, String, Int)
showTransformRuleDet n trans ps e
  = let (e', steps) = runTrExpr trans n (ruleNewVar ps e) e
    in (e', showTransSteps e steps, length steps)

runTrExpr :: TExprTransformationDet -> Int -> VarIndex -> TExpr
         -> (TExpr, [Step])
runTrExpr trans n v e
 | n == 0    = (e,[])
 | otherwise = let (e', s, v', seen) = runRewriter (run trans [] e) v
               in case seen of
                    False -> (e', s)
                    True  -> second (s++) $ runTrExpr trans (n-1) v' e'

-- Bottom-up traversal, applying `trans` at every node. Path convention
-- (matches `FlatCurry.Transform.Typed.Utils.replace`): `-1` for a `TLet`
-- body / `TCase` scrutinee, list index for everything else.
run :: TExprTransformationDet -> Path -> TExpr -> ReWriter TExpr
run _ _ e@(TVarE _ _) = return e
run _ _ e@(TLit _ _)  = return e

run trans p (TComb ty ct n es) = do
  es' <- mapM runExp (zip [0..] es)
  runExprTransform trans p (TComb ty ct n es')
 where runExp (i,e) = run trans (i:p) e

run trans p (TLet bs e) = do
  e'  <- run trans (-1:p) e
  bs' <- mapM runVar (zip [0..] bs)
  runExprTransform trans p (TLet bs' e')
 where runVar (i,(v,le)) = do le' <- run trans (i:p) le
                              return (v,le')

run trans p (TFree vs e) = do
  e' <- run trans (0:p) e
  runExprTransform trans p (TFree vs e')

run trans p (TOr e1 e2) = do
  e1' <- run trans (0:p) e1
  e2' <- run trans (1:p) e2
  runExprTransform trans p (TOr e1' e2')

run trans p (TCase ct e bs) = do
  e'  <- run trans (-1:p) e
  bs' <- mapM runBranch (zip [0..] bs)
  runExprTransform trans p (TCase ct e' bs')
 where runBranch (i,TBranch q b) = do b' <- run trans (i:p) b
                                      return (TBranch q b')

run trans p (TTyped e te) = do
  e' <- run trans (0:p) e
  runExprTransform trans p (TTyped e' te)

-- Apply a totally defined expression transformation to an expression.
runExprTransform :: TExprTransformationDet -> Path -> TExpr -> ReWriter TExpr
runExprTransform trans p e = do
  v <- curVar
  case trans (v,p) e of
    Nothing        -> return e
    Just (e',r,dv) -> do update e' (r,p,e') dv
                         run trans p e'

showTransSteps :: TExpr -> [Step] -> String
showTransSteps _ [] = ""
showTransSteps e ((rule, p, rhs):steps) =
  "=> " ++ rule ++ " " ++ show (reverse p) ++ "\n" ++
  pPrint (ppExp e') ++ "\n" ++
  showTransSteps e' steps
 where
  e' = replace e (reverse p) rhs

------------------------------------------------------------------------------
