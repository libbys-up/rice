------------------------------------------------------------------------------
--- The optimizer: deterministic TypedFlatCurry rewrite rules, run to a
--- fixpoint by `FlatCurry.Transform.Typed.ExecDet`. They inline small
--- functions, cancel cases on known constructors, and drop dead bindings.
---
--- The optimizer runs before ANF, so there are few `Let`s for `inline` to
--- cancel yet; most of the work is done by `reduce`, `caseCancel` and
--- `deadCode`. See the developer's manual, "The optimizer".
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Optimize.Inline
  ( optimizeExpr, optimizeProg, optimizeRules
  , inline, caseCancel, deadCode, reduce
  , subGrounded, inlineCall
 ) where

import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies (isCombTypeFuncCall, isCombTypeConsCall)

import FlatCurry.Transform.Typed.Types   (TExprTransformationDet, combine)
import FlatCurry.Transform.Typed.Utils   (newVar)
import FlatCurry.Transform.Typed.Goodies
  (ground, nonRecursive, strict, hasVar, uses, sub, idSub, (@>), rename
  , isCons, isPart)
import FlatCurry.Transform.Typed.ExecDet (transformExprDet, transformFuncsInProgDet)

import Rice.Optimize.FunTable

------------------------------------------------------------------------------
--- Substitutes a `Let`-bound constructor, partial application or literal
--- into the body:
---
---   let x = C v1..vn in e   ==>   e[x -> C v1..vn]
---   let x = <literal> in e  ==>   e[x -> <literal>]
---
--- A bound `Case` is substituted only when `x` is used exactly once, in a
--- position that forces it anyway (`strict`). Otherwise we'd just move the
--- case, or duplicate it.
inline :: TExprTransformationDet
inline _ expr = case expr of
  TLet [((x,_), f@(TComb _ ct _ _))] e
    | (isCons ct || isPart ct) && nonRecursive x f
    -> Just (sub ((x, Just f) @> idSub) e, "INLINE_CONS", 0)
  TLet [((x,_), l@(TLit _ _))] e
    -> Just (sub ((x, Just l) @> idSub) e, "INLINE_LIT", 0)
  TLet [((x,_), c@(TCase _ _ _))] e
    | strict x e && uses x e == 1
    -> Just (sub ((x, Just c) @> idSub) e, "INLINE_CASE", 0)
  _ -> Nothing

------------------------------------------------------------------------------
--- Case of a known constructor or literal:
---
---   case (C e1..en) of { ...; C x1..xn -> e; ... }  ==>  e[xi -> ei]
---   case <lit> of { ...; <lit> -> e; ... }           ==>  e
---
--- The scrutinee may be wrapped in `TTyped`: an annotated literal like
--- `(3 :: Int)` is `TTyped (TLit ...) Int`.
caseCancel :: TExprTransformationDet
caseCancel _ expr = case expr of
  TCase _ scrutinee bs -> case stripTyped scrutinee of
    TComb _ ct n es
      | isCombTypeConsCall ct
      -> case findConsBranch n bs of
           Nothing      -> Nothing
           Just (vs, e) -> Just (subGrounded e vs es, "CASE_CANCEL_CONS", 0)
    TLit _ l
      -> case findLitBranch l bs of
           Nothing -> Nothing
           Just e  -> Just (e, "CASE_CANCEL_LIT", 0)
    _ -> Nothing
  _ -> Nothing

--- Removes any `TTyped` wrappers.
stripTyped :: TExpr -> TExpr
stripTyped e = case e of
  TTyped e' _ -> stripTyped e'
  _           -> e

findConsBranch :: QName -> [TBranchExpr] -> Maybe ([VarIndex], TExpr)
findConsBranch n bs = case filter isMatch bs of
    (TBranch (TPattern _ _ vs) e:_) -> Just (map fst vs, e)
    _                                -> Nothing
 where isMatch b = case b of
                     TBranch (TPattern _ n' _) _ -> n == n'
                     TBranch (TLPattern _ _)   _ -> False

findLitBranch :: Literal -> [TBranchExpr] -> Maybe TExpr
findLitBranch l bs = case filter isMatch bs of
    (TBranch _ e:_) -> Just e
    _                -> Nothing
 where isMatch b = case b of
                     TBranch (TLPattern _ l') _ -> l == l'
                     TBranch (TPattern _ _ _) _ -> False

------------------------------------------------------------------------------
--- Drops bindings nothing refers to.
---
--- An unused `Let` of type `IO a` has to stay: a `do` block's non-final
--- statement can become `let _ = statement in rest`, and the statement's
--- effect still has to happen. Every other type is pure.
deadCode :: TExprTransformationDet
deadCode _ expr = case expr of
  TFree [] e -> Just (e, "DEAD_CODE", 0)
  TLet  [] e -> Just (e, "DEAD_CODE", 0)
  TFree [(v,_)] e
    | not (hasVar v e) -> Just (e, "DEAD_CODE", 0)
  TLet [((v,ty),_)] e
    | not (hasVar v e) && not (isIOType ty) -> Just (e, "DEAD_CODE", 0)
  TLet [((x,_),e)] (TVarE _ y)
    | x == y && not (hasVar x e) -> Just (e, "DEAD_CODE", 0)
  _ -> Nothing

--- Is this type `Prelude.IO t`?
isIOType :: TypeExpr -> Bool
isIOType ty = case ty of
  TCons ("Prelude", "IO") _ -> True
  _                         -> False

------------------------------------------------------------------------------
--- Substitutes a call's arguments for the callee's parameters `vs`.
--- Ground arguments (variables, literals, ground constructor applications)
--- are substituted directly. Everything else is bound once with a `Let`, so
--- it's still evaluated at most once and shared. That's what makes
--- inlining safe: we never duplicate work or a choice.
---
--- `vs` and `args` must be the same length. If they aren't, the callee was
--- declared with the wrong arity (for example a `replace/` override with a
--- different type from the function it replaces), and we stop here rather
--- than leave a parameter unbound.
subGrounded :: TExpr -> [VarIndex] -> [TExpr] -> TExpr
subGrounded e vs args
  | length vs /= length args = error $
      "Rice.Optimize.Inline.subGrounded: " ++ show (length vs) ++
      " parameter(s) but " ++ show (length args) ++ " argument(s) -- " ++
      "a real arity mismatch, not something to substitute past"
  | otherwise = foldr bindLet (sub gsub e) lets
 where
  ves      = zip vs args
  gsub     = foldr (@>) idSub [ (v, Just a) | (v,a) <- ves, ground a ]
  lets     = [ (v,a) | (v,a) <- ves, not (ground a) ]
  bindLet (v,a) body' = TLet [((v, typeOf a), a)] body'

--- Inline a fully-saturated call to `f` with the given arguments,
--- renaming the callee's body apart first so its variables can't clash
--- with the caller's. Returns the inlined expression and how many fresh
--- variables it used.
inlineCall :: FunTable -> VarIndex -> QName -> [TExpr] -> (TExpr, VarIndex)
inlineCall ft n f args = (subGrounded renamedBody ps args, n2 - n)
 where
  callee            = body ft f
  ps'               = params ft f
  n1                = max (freshVar ft f) n
  ps                = take (length ps') [n1 ..]
  renaming          = foldr (@>) id (zip ps' ps)
  (renamedBody, n2) = rename (n1 + length ps') renaming callee

--- Inline any fully-saturated call to an `inlinable` function.
reduce :: FunTable -> TExprTransformationDet
reduce ft (n,_) expr = case expr of
  TComb _ ct f args
    | isCombTypeFuncCall ct && inlinable ft f
    -> let (e', dn) = inlineCall ft n f args in Just (e', "REDUCE", dn)
  _ -> Nothing

------------------------------------------------------------------------------

--- All of the rules above, tried in order and run to a fixpoint.
optimizeRules :: FunTable -> TExprTransformationDet
optimizeRules ft = combine [ caseCancel, deadCode, inline, reduce ft ]

optimizeExpr :: FunTable -> TExpr -> TExpr
optimizeExpr ft = transformExprDet (optimizeRules ft)

--- Run the optimizer over every function body in a program.
optimizeProg :: FunTable -> TProg -> TProg
optimizeProg ft = transformFuncsInProgDet (optimizeRules ft)

------------------------------------------------------------------------------
