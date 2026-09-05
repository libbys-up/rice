------------------------------------------------------------------------------
--- General-purpose helpers for writing TypedFlatCurry expression
--- transformations: groundness/recursion/strictness tests, substitution,
--- and renaming.
---
--- These used to live in `flatcurry-transform`'s own (untyped)
--- `FlatCurry.Transform.Utils`, but got trimmed out of that module at some
--- point (its current published version only keeps the rewrite-engine
--- plumbing: `ReWriter`/`curVar`/`update`/`newVar`/`replace`, see
--- `FlatCurry.Transform.Typed.Utils`). This module is the `TExpr`
--- counterpart of that older, fuller set, kept under `FlatCurry/Transform/
--- Typed` for the same migration reason as its siblings.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module FlatCurry.Transform.Typed.Goodies
  ( missingVars, ground, recursive, nonRecursive
  , hasVar, uses, freeVarsOf, strict
  , isFunc, isCons, isPart, isApp
  , Subst, idSub, (@>), (-\), sub
  , rename, fresh
  , mapFst, mapSnd, mergeMap, merge, (++-), (\\-)
 ) where

import Data.List               ( sort, sum )
import Control.Monad.Trans.State

import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies ( missingCombArgs, tBranchTExpr
                                , isCombTypeFuncCall, isCombTypeFuncPartCall
                                , isCombTypeConsCall, isCombTypeConsPartCall
                                )

infixr 5 ++-, \\-

------------------------------------------------------------------------------
-- CombType classification (representation-independent -- CombType is the
-- same type for typed and untyped FlatCurry -- so this is just naming the
-- combinations of FlatCurry.Typed.Goodies' isCombType* predicates that
-- transformation rules actually want to ask for.)

isFunc :: CombType -> Bool
isFunc ct = isCombTypeFuncCall ct || isCombTypeFuncPartCall ct

isCons :: CombType -> Bool
isCons = not . isFunc

isPart :: CombType -> Bool
isPart ct = isCombTypeFuncPartCall ct || isCombTypeConsPartCall ct

isApp :: CombType -> Bool
isApp = not . isPart

------------------------------------------------------------------------------
-- Checking a partial application hiding under lets/frees/or.
-- I'll allow hiding under choice only if both branches are missing the
-- same number of arguments.

missingVars :: TExpr -> Int
missingVars e@(TComb _ _ _ _) = missingCombArgs e
missingVars (TVarE _ _)       = 0
missingVars (TLit _ _)        = 0
missingVars (TFree _ e)       = missingVars e
missingVars (TTyped e _)      = missingVars e
missingVars (TLet _ e)        = missingVars e
missingVars (TCase _ _ _)     = 0
missingVars (TOr e1 e2)
  | n1 == n2  = n1
  | otherwise = 0
 where n1 = missingVars e1
       n2 = missingVars e2

------------------------------------------------------------------------------
--- Is this expression safe to substitute directly, without wrapping it in
--- a `Let` first? A variable reference or literal qualifies (substituting
--- either is just a rename, nothing gets duplicated); so does a
--- constructor application built entirely from ground pieces.
---
--- NOTE: deliberately not the same thing as `FlatCurry.Typed.Goodies.
--- isGround`, which does *not* count a bare variable reference as ground
--- (it means "fully evaluated data value", a stricter, different notion).
--- This is the "safe to substitute without duplicating deferred work"
--- sense instead -- the property `FlatCurry.Build.Inline`'s ground-vs-let
--- argument handling actually needs.
ground :: TExpr -> Bool
ground (TVarE _ _)       = True
ground (TLit _ _)        = True
ground (TComb _ ct _ es) = isCombTypeConsCall ct && all ground es
ground (TFree _ _)       = False
ground (TOr _ _)         = False
ground (TTyped e _)      = ground e
ground (TLet _ _)        = False
ground (TCase _ _ _)     = False

------------------------------------------------------------------------------
--- In `let x = e in ...`, does `e` refer to `x`?
recursive :: VarIndex -> TExpr -> Bool
recursive x (TVarE _ y)      = x == y
recursive _ (TLit _ _)       = False
recursive x (TComb _ _ _ es) = any (recursive x) es
recursive x (TOr e1 e2)      = any (recursive x) [e1,e2]
recursive x (TTyped e _)     = recursive x e

recursive x (TFree vs e)
 | x `elem` map fst vs = False
 | otherwise           = recursive x e

recursive x (TLet bs e)
 | x `elem` map (fst . fst) bs = False
 | otherwise                   = any (recursive x) (e : map snd bs)

-- NOTE: the source this was ported from ties the scrutinee and the
-- branches together with `&&` here, which looks like a bug -- every
-- other clause in `recursive` is "used anywhere" (`any`/`||`-shaped), and
-- there's no reason `x` occurring only in the scrutinee shouldn't count.
-- Using `||` instead.
recursive x (TCase _ e bs) = recursive x e || any recursiveBranch bs
 where recursiveBranch (TBranch (TLPattern _ _) be) = recursive x be
       recursiveBranch (TBranch (TPattern _ _ vs) be)
        | x `elem` map fst vs = False
        | otherwise           = recursive x be

nonRecursive :: VarIndex -> TExpr -> Bool
nonRecursive x = not . recursive x

------------------------------------------------------------------------------

hasVar :: VarIndex -> TExpr -> Bool
hasVar x e = uses x e > 0

uses :: VarIndex -> TExpr -> Int
uses x (TVarE _ v)      = if x == v then 1 else 0
uses _ (TLit _ _)       = 0
uses x (TComb _ _ _ es) = sum (map (uses x) es)
uses x (TFree vs e)     = if x `elem` map fst vs then 0 else uses x e
uses x (TOr e1 e2)      = uses x e1 + uses x e2
uses x (TTyped e _)     = uses x e
uses x (TLet bs e)      = if x `elem` map (fst . fst) bs
                            then 0
                            else sum (map (uses x . snd) bs) + uses x e
uses x (TCase _ e bs)   = uses x e + sum (map useBranch bs)
 where useBranch (TBranch (TPattern _ _ vs) be) =
         if x `elem` map fst vs then 0 else uses x be
       useBranch (TBranch (TLPattern _ _) be) = uses x be

------------------------------------------------------------------------------

freeVarsOf :: TExpr -> [VarIndex]
freeVarsOf (TVarE _ v)      = [v]
freeVarsOf (TLit _ _)       = []
freeVarsOf (TComb _ _ _ es) = mergeMap freeVarsOf es
freeVarsOf (TFree vs e)     = freeVarsOf e \\- sort (map fst vs)
freeVarsOf (TOr e1 e2)      = freeVarsOf e1 ++- freeVarsOf e2
freeVarsOf (TTyped e _)     = freeVarsOf e
freeVarsOf (TLet bs e)      =
  mergeMap freeVarsOf (e : map snd bs) \\- sort (map (fst . fst) bs)
freeVarsOf (TCase _ e bs)   = freeVarsOf e ++- mergeMap freeBranch bs
 where freeBranch (TBranch (TPattern _ _ vs) be) =
         freeVarsOf be \\- sort (map fst vs)
       freeBranch (TBranch (TLPattern _ _) be) = freeVarsOf be

------------------------------------------------------------------------------
--- Is `x` used at most once in the expression, in a context guaranteed to
--- evaluate it? Right now that means: `x` is the scrutinee of a `Case`,
--- or `x` is the first (unapplied-under-anything-else) argument of
--- `Prelude.apply`, or `x` is a branch of a `Case`.
--- `let y = apply x ...` is fine; `f (apply x ...)` is not, because `f`
--- might not be strict.
strict :: VarIndex -> TExpr -> Bool
strict _ (TVarE _ _)  = False
strict _ (TLit _ _)   = False
strict _ (TOr _ _)    = False
strict x (TTyped e _) = strict x e
strict x (TFree _ e)  = strict x e

strict x (TLet bs e) =
  let es = e : map snd bs
  in sum (map (uses x) es) == 1 && length (filter (strict x) es) == 1

strict x (TComb _ _ n es) =
  n == ("Prelude","apply") && not (null es) && isVarIndex x (head es) &&
  not (any (hasVar x) (tail es))

strict x (TCase _ e bs)
 | isVarIndex x e        = not (any (hasVar x . tBranchTExpr) bs)
 | strictBranch False bs = not (hasVar x e)
 | otherwise              = not (hasVar x e) && any (strict x . tBranchTExpr) bs
 where
  strictBranch found []                 = found
  strictBranch found (TBranch _ e':bs')
   | isVarIndex x e' = strictBranch True bs'
   | otherwise        = not (hasVar x e') && strictBranch found bs'

-- Written with a `case` (rather than two top-level equations, which the
-- compiler can't always prove are mutually exclusive) so this stays
-- deterministic -- see FlatCurry.Transform.Typed.Utils' note on
-- kics2's nondeterminism overhead.
isVarIndex :: VarIndex -> TExpr -> Bool
isVarIndex x e = case e of
                   TVarE _ v -> v == x
                   _         -> False

------------------------------------------------------------------------------
-- Substitution.
--
-- `Subst` returns `Nothing` for a variable that isn't substituted, so
-- `sub` can reconstruct `TVarE ty v` using the type already in hand at
-- that occurrence -- unlike the expression being substituted in, that
-- type never needs to be threaded through the substitution function
-- itself.

--- A substitution: `Nothing` leaves the variable as-is.
type Subst = VarIndex -> Maybe TExpr

--- The empty substitution.
idSub :: Subst
idSub _ = Nothing

--- Add `x -> e` to a substitution.
(@>) :: (Eq a) => (a,b) -> (a -> b) -> (a -> b)
(x,e) @> s = \v -> if x == v then e else s v

--- Remove `xs` from a substitution's domain (they're shadowed).
(-\) :: Subst -> [VarIndex] -> Subst
s -\ xs = \v -> if v `elem` xs then Nothing else s v

--- Apply a substitution to an expression.
sub :: Subst -> TExpr -> TExpr
sub s e@(TVarE _ v) = case s v of
                        Just e' -> e'
                        Nothing -> e
sub _ l@(TLit _ _)      = l
sub s (TOr e1 e2)       = TOr (sub s e1) (sub s e2)
sub s (TTyped e t)      = TTyped (sub s e) t
sub s (TComb ty ct n es) = TComb ty ct n (map (sub s) es)
sub s (TFree vs e)      = TFree vs (sub (s -\ map fst vs) e)
sub s (TLet bs e)       = TLet (map (mapSnd (sub s')) bs) (sub s' e)
 where s' = s -\ map (fst . fst) bs
sub s (TCase t e bs)    = TCase t (sub s e) (map branchSub bs)
 where branchSub (TBranch p@(TPattern _ _ vs) be) =
         TBranch p (sub (s -\ map fst vs) be)
       branchSub (TBranch p@(TLPattern _ _) be) = TBranch p (sub s be)

------------------------------------------------------------------------------
-- Renaming. Can't reuse `sub` for this: we're replacing every occurrence
-- of a variable *name*, and binder positions (like a `Let`'s bound
-- variable) aren't expression positions `sub` can reach.

--- Rename variables in an expression, given a starting fresh-variable
--- counter (see `FlatCurry.Transform.Typed.Utils.newVar`) and a renaming
--- for the expression's free variables. Returns the renamed expression
--- and the next unused variable index.
rename :: VarIndex -> (VarIndex -> VarIndex) -> TExpr -> (TExpr, VarIndex)
rename n s e = runState (ren s e) n

ren :: (VarIndex -> VarIndex) -> TExpr -> State VarIndex TExpr
ren s (TVarE ty v) = return $ TVarE ty (s v)
ren _ l@(TLit _ _) = return l
ren s (TFree vs e) = do s' <- extend (map fst vs) s
                        e' <- ren s' e
                        return $ TFree (map (mapFst s') vs) e'
ren s (TLet bs e)  = do s'  <- extend (map (fst . fst) bs) s
                        bs' <- mapM (renBind s') bs
                        e'  <- ren s' e
                        return $ TLet bs' e'
 where renBind t ((v,ty),le) = do le' <- ren t le
                                  return ((t v, ty), le')
ren s (TOr e1 e2)  = do e1' <- ren s e1
                        e2' <- ren s e2
                        return $ TOr e1' e2'
ren s (TTyped e t) = do e' <- ren s e
                        return $ TTyped e' t
ren s (TComb ty ct n es) = do es' <- mapM (ren s) es
                              return $ TComb ty ct n es'
ren s (TCase ct e bs) = do e'  <- ren s e
                           bs' <- mapM branchRen bs
                           return $ TCase ct e' bs'
 where
  branchRen (TBranch (TPattern ty n vs) be) = do
    s'  <- extend (map fst vs) s
    be' <- ren s' be
    return $ TBranch (TPattern ty n (map (mapFst s') vs)) be'
  branchRen (TBranch p@(TLPattern _ _) be) = do
    be' <- ren s be
    return $ TBranch p be'

-- Extend a renaming with fresh names for `vs`. As in the source this was
-- ported from: `-1` is a placeholder that's never actually a variable (a
-- pattern-match wildcard slot) and is left alone; a negative index is
-- renamed to a fresh negative index (used elsewhere for some
-- otherwise-unrelated naming convention this module doesn't otherwise
-- know about) instead of a fresh ordinary one.
extend :: [VarIndex] -> (VarIndex -> VarIndex) -> State VarIndex (VarIndex -> VarIndex)
extend []     s = return s
extend (v:vs) s
 | v == -1   = extend vs s
 | v >= 0    = do n <- fresh
                  extend vs ((v,n) @> s)
 | otherwise = do n <- fresh
                  extend vs ((v,-n) @> s)

--- Get a fresh variable index, threading a counter through the State
--- monad. Returns the current counter and advances it by one.
fresh :: State VarIndex VarIndex
fresh = do v <- get
           put (v+1)
           return v

------------------------------------------------------------------------------
-- General utilities. Kept local (rather than importing Rice.Util, which
-- has equivalents) so this module doesn't depend on Rice -- the whole
-- point of putting it here is that it can migrate into flatcurry-transform
-- without dragging Rice along.

mapFst :: (a -> c) -> (a,b) -> (c,b)
mapFst f (x,y) = (f x, y)

mapSnd :: (b -> d) -> (a,b) -> (a,d)
mapSnd f (x,y) = (x, f y)

--- Like `concatMap`, but for sorted, duplicate-free lists: merges the
--- results with `(++-)` instead of `(++)`.
mergeMap :: (Ord b) => (a -> [b]) -> [a] -> [b]
mergeMap f = merge . map f

--- Merge a list of sorted, duplicate-free lists into one.
merge :: (Ord a) => [[a]] -> [a]
merge xs = case xs of
                []  -> []
                [x] -> x
                _   -> merge (pair xs)
 where pair ys = case ys of
                   (z1:z2:zs) -> (z1 ++- z2) : pair zs
                   _          -> ys

--- Duplicate-free union of two sorted lists. O(n).
(++-) :: (Ord a) => [a] -> [a] -> [a]
[]     ++- ys     = ys
(x:xs) ++- []     = x : xs
(x:xs) ++- (y:ys) = case compare x y of
                         LT -> x : (xs ++- (y:ys))
                         EQ -> x : (xs ++- ys)
                         GT -> y : ((x:xs) ++- ys)

--- Difference of two sorted lists. O(n).
(\\-) :: (Ord a) => [a] -> [a] -> [a]
[]     \\- _      = []
(x:xs) \\- []     = x:xs
(x:xs) \\- (y:ys) = case compare x y of
                         LT -> x : (xs \\- (y:ys))
                         EQ -> xs \\- ys
                         GT -> (x:xs) \\- ys

------------------------------------------------------------------------------
