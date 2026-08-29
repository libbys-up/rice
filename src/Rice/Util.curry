module Rice.Util ((++-), (\\-), merge, mergeMap, accM, 
                  vars, fresh, newVar) where

import Data.List (sort, maximum)
import FlatCurry.Typed.Types
import Control.Monad.Trans.State (get, put, State)

--- get all variables from FlatCurry expression
vars :: TExpr -> [VarIndex]
vars (TVarE _ v)       = [v]
vars (TLit _ l)        = []
vars (TComb _ ct n es) = mergeMap vars es
vars (TLet vs e)       = mergeMap vars (e : map snd vs) ++- sort (map (fst . fst) vs)
vars (TFree vs e)      = vars e ++- sort (map fst vs)
vars (TOr e1 e2)       = vars e1 ++- vars e2
vars (TCase ct e bs)   = merge (vars e : map branchVars bs)
vars (TTyped e t)      = vars e

branchVars :: TBranchExpr -> [VarIndex]
branchVars (TBranch (TLPattern _ _)   e) = vars e
branchVars (TBranch (TPattern _ _ vs) e) = vars e \\- sort (map fst vs)

newVar :: TExpr -> VarIndex
newVar (TVarE _ v)        = v
newVar (TLit _ l)         = 0
newVar (TComb _ _ _ es)   = foldr max 0 (map newVar es)
newVar (TLet vs e)        = foldr letVar (newVar e) vs
 where letVar ((v,_),e) m = maximum [v, newVar e, m]
newVar (TOr e1 e2)        = max (newVar e1) (newVar e2)
newVar (TFree vs e)       = maximum (newVar e : map fst vs)
newVar (TTyped e _)       = newVar e
newVar (TCase _ e bs)     = maximum (newVar e : map newVarBranch bs)
  where newVarBranch (TBranch (TLPattern _ _) e) = newVar e
        newVarBranch (TBranch (TPattern _ _ vs) e) = maximum (newVar e : map fst vs)


-- no duplicate union
-- O(n)
(++-) :: (Ord a) => [a] -> [a] -> [a]
[]     ++- ys     = ys
(x:xs) ++- []     = x : xs
(x:xs) ++- (y:ys) = case compare x y of
                         LT -> x : (xs ++- (y:ys))
                         EQ -> x : (xs ++- ys)
                         GT -> y : ((x:xs) ++- ys)

-- no duplicate difference
-- O(n)
(\\-) :: (Ord a) => [a] -> [a] -> [a]
[]     \\- _      = []
(x:xs) \\- []     = x:xs
(x:xs) \\- (y:ys) = case compare x y of
                         LT -> x : (xs \\- (y:ys))
                         EQ -> xs \\- ys
                         GT -> (x:xs) \\- ys

--- intersection
--- O(n)
(&&-) :: (Ord a) => [a] -> [a] -> [a]
[]     &&- _      = []
(x:xs) &&- []     = []
(x:xs) &&- (y:ys) = case compare x y of
                         LT ->     xs &&- (y:ys)
                         EQ -> x : (xs &&- ys)
                         GT ->     (x:xs) &&- ys

-- like concatMap without duplicates
-- worst case O(n*log(n))
-- usually O(n)
mergeMap :: (Ord b) => (a -> [b]) -> [a] -> [b]
mergeMap f = merge . map f

merge :: (Ord a) => [[a]] -> [a]
merge xs = case xs of
                []  -> []
                [x] -> x
                _   -> merge (pair xs)
 where pair []         = []
       pair [x]        = [x]
       pair (x1:x2:xs) = (x1 ++- x2) : pair xs

-- make a new variable in the State monad
fresh :: State VarIndex VarIndex
fresh = do x <- get
           put (x+1)
           return (x+1)

-- This is just a useful monad function
accM :: (Monad m) => (a -> b -> m ([c],b)) -> b -> [a] -> m ([c],b)
accM _ acc []     = return ([], acc)
accM f acc (x:xs) = do (r,  acc') <- f x acc
                       (rs, acc'') <- accM f acc' xs
                       return (r ++ rs, acc'')
