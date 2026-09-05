------------------------------------------------------------------------------
--- Utility operations to execute program transformations on TypedFlatCurry
--- programs.
---
--- This is the typed (`TExpr`) counterpart of `FlatCurry.Transform.Utils`
--- from the `flatcurry-transform` package (see `FlatCurry.Transform.Typed.
--- Types` for why this lives under `FlatCurry/Transform/Typed`). It only
--- covers what the untyped package's `Utils` module currently covers: the
--- plumbing the rewrite engine itself needs (`ReWriter`, `newVar`,
--- `replace`). Anything a specific transformation needs beyond that
--- (`ground`, substitution, renaming, free variables, ...) is expected to
--- live with the transformation, same as upstream.
---
--- @author Steven Libby
------------------------------------------------------------------------------
{-# OPTIONS_FRONTEND -Wno-incomplete-patterns #-}

module FlatCurry.Transform.Typed.Utils
  ( ReWriter(..), curVar, newVar, replace, update )
 where

import FlatCurry.Typed.Types

import FlatCurry.Transform.Typed.Types

------------------------------------------------------------------------------
--- Replace a subexpression in an expression, i.e., `replace e p w`
--- implements `e[w]_p`. Path convention matches
--- `FlatCurry.Transform.Typed.ExecDet.run`: `-1` selects the `TLet` body /
--- `TCase` scrutinee, everything else is a list index.
replace :: TExpr -> Path -> TExpr -> TExpr
replace _               []     w = w
replace (TFree vs e)    (0:ps) w = TFree vs (replace e ps w)
replace (TOr e1 e2)     (0:ps) w = TOr (replace e1 ps w) e2
replace (TOr e1 e2)     (1:ps) w = TOr e1 (replace e2 ps w)
replace (TTyped e t)    (0:ps) w = TTyped (replace e ps w) t

replace (TComb ty ct n es) (p:ps) w = TComb ty ct n (x ++ [replace e ps w] ++ y)
  where (x, e:y) = splitAt p es

replace (TLet bs e) (p:ps) w
 | p == -1   = TLet bs (replace e ps w)
 | otherwise = TLet bs' e
  where (x, (v,ve):y) = splitAt p bs
        bs' = x ++ [(v, replace ve ps w)] ++ y

replace (TCase t e bs) (p:ps) w
 | p == -1   = TCase t (replace e ps w) bs
 | otherwise = TCase t e bs'
  where (x, TBranch f be:y) = splitAt p bs
        bs' = x ++ [TBranch f (replace be ps w)] ++ y

------------------------------------------------------------------------------
--- Returns the next unused variable index in an expression, i.e. one
--- greater than the largest variable index (bound or free) occurring in
--- it. Note this is "next fresh", not "largest used" -- callers (the
--- rewrite engine in particular) rely on being able to use this directly
--- as a starting counter.
newVar :: TExpr -> VarIndex
newVar (TVarE _ v)      = v + 1
newVar (TLit _ _)       = 1
newVar (TComb _ _ _ es) = foldr (max . newVar) 1 es
newVar (TFree vs e)     = max (max1 (map fst vs) + 1) (newVar e)
newVar (TOr e1 e2)      = max (newVar e1) (newVar e2)
newVar (TTyped e _)     = newVar e
newVar (TLet bs e)      = max (newVar e) (foldr maxLet 1 bs)
 where maxLet ((v,_),le) m = m `max` (v + 1) `max` newVar le
newVar (TCase _ e bs)   = max (newVar e) (foldr (max . maxBranch) 1 bs)
 where maxBranch (TBranch (TPattern _ _ vs) be) =
         max (max1 (map fst vs) + 1) (newVar be)
       maxBranch (TBranch (TLPattern _ _) be) = newVar be

max1 :: [Int] -> Int
max1 = foldr max 0

------------------------------------------------------------------------------
-- The type `ReWriter` is an extension of the Writer monad.
-- It is used to execute program transformations. Generic over `Step`
-- (imported from `FlatCurry.Transform.Typed.Types`), so nothing here is
-- actually TExpr-specific -- it's identical to the untyped package's
-- `ReWriter` up to which `Step` is in scope.
newtype ReWriter a =
  ReWriter { runRewriter :: VarIndex -> (a, [Step], VarIndex, Bool) }

instance Functor ReWriter
 where
  fmap _ _ = error "ReWriter.fmap"

instance Applicative ReWriter where
  pure x = ReWriter $ \v -> (x,[],v,False)
  _ <*> _ = error "ReWriter.<*>"

instance Monad ReWriter where
 return = pure
 (ReWriter h) >>= f
  = ReWriter $ \v ->
     case h v of
      (e1, steps1, v1, seen1) ->
       case f e1 of
        (ReWriter g) ->
         case g v1 of
          (e2, steps2, v2, seen2) -> (e2, steps1 ++ steps2, v2, seen1 || seen2)

curVar :: ReWriter VarIndex
curVar = ReWriter $ \v -> (v,[],v,False)

update :: a -> Step -> VarIndex -> ReWriter a
update e step dv = ReWriter $ \v -> case v + dv of
                                      n -> (e, [step], n, True)

------------------------------------------------------------------------------
