------------------------------------------------------------------------------
--- The inliner: a set of deterministic TypedFlatCurry rewrite rules
--- (built on `FlatCurry.Transform.Typed.ExecDet`) that cancel out
--- constructor/literal/case `Let`-bindings, and substitute calls to small
--- functions in place of the call.
---
--- Currently runs directly on `replace`'s output, before any ANF
--- conversion at all -- correct regardless (see `subGrounded`: nothing
--- ever gets duplicated, independent of what ANF stage the expression is
--- in), but `inline`'s `Let`-cancellation rules only have much to do once
--- something has actually introduced `Let`s to cancel. The plan from
--- design discussion was a "limited" ANF pass (outlining calls/case
--- scrutinees but not constructors/literals) immediately before
--- optimization specifically to give those rules more to work with; that
--- pass (`normalizeLimited`, a sibling to `Rice.Transform.ANF.normalize`)
--- doesn't exist yet, so `reduce`/`caseCancel`/`deadCode` are doing most
--- of the real work for now.
---
--- Ported from old_rice's `Optimize/Inline.curry`.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Optimize.Inline
  ( optimizeExpr, optimizeProg, optimizeRules
  , inline, caseCancel, deadCode, reduce
  , subGrounded, inlineCall
 ) where

import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies (isCombTypeFuncCall, isCombTypeConsCall
                                , updTProgTExps)

import FlatCurry.Transform.Typed.Types   (TExprTransformationDet, combine)
import FlatCurry.Transform.Typed.Utils   (newVar)
import FlatCurry.Transform.Typed.Goodies
  (ground, nonRecursive, strict, hasVar, uses, sub, idSub, (@>), rename
  , isCons, isPart)
import FlatCurry.Transform.Typed.ExecDet (transformExprDet)

import Rice.Optimize.FunTable

------------------------------------------------------------------------------
-- Constructors, partial applications and literals are deliberately never
-- outlined by `normalizeLimited` (see Rice.Transform.ANF), so they show
-- up sitting directly in `Let`s the way ordinary ANF-outlined
-- subexpressions do. This rule cancels those back out once they've served
-- their purpose as a case scrutinee or call argument.
--
--   let x = C v1..vn in e   ==>   e[x -> C v1..vn]
--   let x = <literal> in e  ==>   e[x -> <literal>]
--
-- A `Case` binding gets the same treatment, but only when `x` is used
-- exactly once and in a position guaranteed to force it anyway (`strict`)
-- -- otherwise this would just relocate the case, not simplify anything,
-- and could even duplicate it.
-- One equation dispatching via `case` (rather than several top-level
-- equations ending in a catch-all), so this stays deterministic instead
-- of the compiler treating the clauses as potentially-overlapping
-- choices -- see FlatCurry.Transform.Typed.Goodies' note on kics2's
-- nondeterminism overhead.
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
-- case-of-known-constructor / case-of-known-literal:
--
--   case (C e1..en) of { ...; C x1..xn -> e; ... }  ==>  e[xi -> ei]
--   case <lit> of { ...; <lit> -> e; ... }           ==>  e
caseCancel :: TExprTransformationDet
caseCancel _ expr = case expr of
  TCase _ (TComb _ ct n es) bs
    | isCombTypeConsCall ct
    -> case findConsBranch n bs of
         Nothing      -> Nothing
         Just (vs, e) -> Just (subGrounded e vs es, "CASE_CANCEL_CONS", 0)
  TCase _ (TLit _ l) bs
    -> case findLitBranch l bs of
         Nothing -> Nothing
         Just e  -> Just (e, "CASE_CANCEL_LIT", 0)
  _ -> Nothing

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
--- Prune bindings nothing refers to.
---
--- A `Let`'s bound expression is *not* safe to drop just because its
--- variable goes unused when that expression has type `IO a`: running it
--- is the whole reason `>>`/`*>`'s desugaring (a `do`-block's non-final
--- statements ANF-normalize to exactly `let _ = statement in rest`) put
--- it there -- the returned value is meant to be discarded, but the
--- *effect* still has to happen. Every other type in Curry is pure (no
--- observable effect from evaluating and discarding a value of it), so
--- this only needs to special-case `IO`.
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

--- Whether a type is (an application of) `Prelude.IO`. Only looks at the
--- outermost type constructor: a `Let`'s bound expression is always a
--- saturated value of exactly this type, never a partial application
--- still building up to one.
---
--- Written with a `case` (rather than two top-level equations, which the
--- compiler warned it can't prove are mutually exclusive: "Function
--- `isIOType' is potentially non-deterministic due to overlapping
--- rules") so this stays deterministic -- see FlatCurry.Transform.Typed.
--- Goodies' note on kics2's nondeterminism overhead for the same fix
--- elsewhere. Left as two equations, `deadCode`'s `TLet` rule (the only
--- caller) would nondeterministically choose between dropping and
--- keeping *any* dead `Let` -- including non-`IO` ones like a dropped
--- dictionary argument from `subGrounded` -- which silently poisons the
--- whole optimized module with unresolved choice: forcing it later (e.g.
--- `Rice.Build.Cache.writeOptIfChanged`'s `show`) fails outright with
--- "Non-determinism in IO occured", surfacing downstream as KiCS2's
--- generic "List data with no ground term" once the resulting broken
--- `String` is bridged back to a real Haskell one for `writeFile`.
isIOType :: TypeExpr -> Bool
isIOType ty = case ty of
  TCons ("Prelude", "IO") _ -> True
  _                         -> False

------------------------------------------------------------------------------
--- Substitute a function call's arguments for its parameters. Ground
--- arguments (variables, literals, ground constructor applications) get
--- substituted directly; everything else gets exactly one `Let`, so it's
--- evaluated at most once regardless of how many times the parameter
--- occurs in the body. This is the whole reason inlining here is safe
--- without caring which ANF stage the expression is in: nothing that
--- could be shared or non-deterministic ever gets duplicated.
--- `vs` and `args` must be the same length -- a mismatch means the
--- callee's declared parameter count doesn't match how many arguments
--- this call site actually supplies (a real arity bug upstream, e.g. a
--- `replace_*.curry` override declared with a different type than the
--- real function it replaces -- see `replace/replace_Prelude.curry`'s own
--- note on `(=:=)`/`(=:<=)` for a caught instance). `zip` would silently
--- truncate to the shorter list instead of erroring, leaving whichever
--- parameters ran out of arguments as dangling references nothing binds
--- -- checked explicitly so that surfaces here, at the mismatch, instead
--- of much later as a mysterious "undeclared identifier" from the C
--- compiler.
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
optimizeProg ft = updTProgTExps (optimizeExpr ft)

------------------------------------------------------------------------------
