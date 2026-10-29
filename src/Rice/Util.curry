module Rice.Util ((++-), (\\-), merge, mergeMap, accM,
                  fresh, newVar, updProgFresh) where

import Data.List (maximum)
import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies (updTProgTFuncs, updTFuncTRule)
import Control.Monad.Trans.State (get, put, State, evalState)

--- The largest variable index in an expression (0 if there are none),
--- counting every binder: `let`, `free` and case patterns.
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


--- Union of two sorted lists without duplicates. O(n).
(++-) :: (Ord a) => [a] -> [a] -> [a]
[]     ++- ys     = ys
(x:xs) ++- []     = x : xs
(x:xs) ++- (y:ys) = case compare x y of
                         LT -> x : (xs ++- (y:ys))
                         EQ -> x : (xs ++- ys)
                         GT -> y : ((x:xs) ++- ys)

--- Difference of two sorted lists without duplicates. O(n).
(\\-) :: (Ord a) => [a] -> [a] -> [a]
[]     \\- _      = []
(x:xs) \\- []     = x:xs
(x:xs) \\- (y:ys) = case compare x y of
                         LT -> x : (xs \\- (y:ys))
                         EQ -> xs \\- ys
                         GT -> (x:xs) \\- ys

--- Intersection of two sorted lists without duplicates. O(n).
(&&-) :: (Ord a) => [a] -> [a] -> [a]
[]     &&- _      = []
(x:xs) &&- []     = []
(x:xs) &&- (y:ys) = case compare x y of
                         LT ->     xs &&- (y:ys)
                         EQ -> x : (xs &&- ys)
                         GT ->     (x:xs) &&- ys

--- `concatMap` for sorted lists, without duplicates.
mergeMap :: (Ord b) => (a -> [b]) -> [a] -> [b]
mergeMap f = merge . map f

--- Union of sorted lists, merged in pairs. O(n log k) for k lists.
merge :: (Ord a) => [[a]] -> [a]
merge xs = case xs of
                []  -> []
                [x] -> x
                _   -> merge (pair xs)
 where pair []         = []
       pair [x]        = [x]
       pair (x1:x2:xs) = (x1 ++- x2) : pair xs

--- A fresh variable: one more than the last one handed out.
fresh :: State VarIndex VarIndex
fresh = do x <- get
           put (x+1)
           return (x+1)

--- Runs `f` on the body of every function in a program, where `f` can make
--- fresh variables. The counter starts at the largest variable in the
--- function, parameters included: a parameter the body never uses still
--- has a number, and a new variable mustn't reuse it.
updProgFresh :: (TExpr -> State VarIndex TExpr) -> TProg -> TProg
updProgFresh f = updTProgTFuncs (map (updTFuncTRule updRule))
 where
  updRule rule = case rule of
    TRule ps e    -> TRule ps (evalState (f e) (maximum (newVar e : map fst ps)))
    TExternal _ _ -> rule

--- Maps a monadic function over a list, threading an accumulator and
--- concatenating the results.
accM :: (Monad m) => (a -> b -> m ([c],b)) -> b -> [a] -> m ([c],b)
accM _ acc []     = return ([], acc)
accM f acc (x:xs) = do (r,  acc') <- f x acc
                       (rs, acc'') <- accM f acc' xs
                       return (r ++ rs, acc'')
