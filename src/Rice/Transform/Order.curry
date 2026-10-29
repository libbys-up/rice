
module Rice.Transform.Order (loops, edges, calls, orderFuns, inlineScore)
 where

import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies (tFuncName, tFuncBody, tBranchTExpr,
                                isCombTypeFuncCall, isCombTypeFuncPartCall)
import FlatCurry.Transform.Typed.Goodies (isCons, isPart)

import Data.SCC (scc)
import Data.List (sortBy, maximumBy, delete, maximum)

import Rice.Util

loops :: TProg -> [[String]]
loops (TProg _ _ _ fs _) = (map . map) name $ scc (\x -> [name x]) calls fs

--- Chooses the loop breakers: a set of functions that, if we never inline
--- them, makes inlining terminate. Every cycle in the call graph has one,
--- the member with the highest `inlineScore`, so the rest of a recursive
--- group can still be inlined. Returns the module's functions (the
--- breakers last) and the breakers' names.
---
--- The scoring heuristic is a placeholder; what matters is that we exclude
--- just enough functions, not a whole recursive group.
orderFuns :: TProg -> ([TFuncDecl], [QName])
orderFuns (TProg m _ _ fs _) =
  case sccSort fs of
    (ok, breakers) -> (ok ++ breakers, map (\f -> (m, name f)) breakers)

--- Repeatedly removes the highest-`inlineScore` member of each strongly
--- connected component of the call graph until none is left with a cycle.
--- Returns the functions that are safe to inline, and the loop breakers.
sccSort :: [TFuncDecl] -> ([TFuncDecl], [TFuncDecl])
sccSort fs = case fs of
  [f] | name f `elem` calls f -> ([], [f])
      | otherwise             -> ([f], [])
  _ -> concatComps (map sortComp (scc (\f -> [name f]) calls fs))
 where
  sortComp grp = case grp of
    [f] -> sccSort [f]
    _   -> case sccSort (delete breaker grp) of
             (ok, breakers) -> (ok, breaker : breakers)
     where
      breaker  = maximumBy scoreOrd grp
      scoreOrd f1 f2 = compare (score f1) (score f2)
      score    = inlineScore . tFuncBody

concatComps :: [([a],[a])] -> ([a],[a])
concatComps = foldr (\(as,bs) (ass,bss) -> (as ++ ass, bs ++ bss)) ([],[])

--- A rough cost of inlining this body: high for control flow (`Case`,
--- `Or`), low for building data. Only used to pick loop breakers.
inlineScore :: TExpr -> Int
inlineScore (TVarE _ _)        = 0
inlineScore (TLit _ _)         = 0
inlineScore (TComb _ ct _ _)   = if isCons ct || isPart ct then 0 else 1
inlineScore (TLet bs e)        =
  1 + max (inlineScore e) (maximum (map (inlineScore . snd) bs))
inlineScore (TFree _ e)        = 1 + inlineScore e
inlineScore (TOr e1 e2)        = 4 + max (inlineScore e1) (inlineScore e2)
inlineScore (TCase _ e bs)     =
  2 + max (inlineScore e) (maximum (map (inlineScore . tBranchTExpr) bs))
inlineScore (TTyped e _)       = inlineScore e

showMap :: (Show a, Show b) => [(a,[b])] -> String
showMap = unlines . map showGroup
 where showGroup (a,bs) = unlines (show a : (map showCall bs))
       showCall b = " -> " ++ show b

edges :: [TFuncDecl] -> [(String,String)]
edges = concatMap makeEdges . sortFuns
 where sortFuns    = sortBy (\x y -> name x <= name y)
       makeEdges f = map (\n -> (name f,n)) $ calls f

group :: (Eq a) => [(a,b)] -> [(a,[b])]
group []         = []
group ((a,b):cs) = case span ((==a) . fst) cs of
                        (as,bs) -> (a, b : map snd as) : group bs

calls :: TFuncDecl -> [String]
calls (TFunc _ _ _ _ (TExternal _ _)) = []
calls (TFunc _ _ _ _ (TRule _ b)) = get b
 where 
   get (TVarE _ _)         = []
   get (TLit _ _)          = []
   get (TLet vs e)         = mergeMap get (e : map snd vs)
   get (TOr e1 e2)         = get e1 ++- get e2
   get (TFree _ e)         = get e
   get (TCase _ e bs)      = merge (get e : map (get . tBranchTExpr) bs)
   get (TTyped e _)        = get e
   get (TComb _ ct (_,n) es) 
    | isFunc ct = [n] ++- mergeMap get es
    | otherwise = mergeMap get es


isFunc :: CombType -> Bool
isFunc c = isCombTypeFuncCall c || isCombTypeFuncPartCall c

name :: TFuncDecl -> String
name = snd . tFuncName

