
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

--- A module's functions, reordered so that (as much as the call graph
--- allows) a function comes after everything it calls, together with the
--- names of the functions picked as "loop breakers": one per irreducible
--- cycle in the call graph, chosen by `inlineScore` (a rough
--- "how much would inlining this cost" estimate -- the priciest member of
--- a cycle is excluded, so the rest of the cycle stays safely inlinable
--- instead of the whole group being excluded).
---
--- Ported from old_rice's `Optimize/LoopBreakers.curry` (`orderFuns`/
--- `sccSort`). The breaker-selection heuristic itself is expected to
--- change -- what matters is the pattern: exclude exactly enough
--- functions to make inlining terminate, not an entire recursive group.
orderFuns :: TProg -> ([TFuncDecl], [QName])
orderFuns (TProg m _ _ fs _) =
  case sccSort fs of
    (ok, breakers) -> (ok ++ breakers, map (\f -> (m, name f)) breakers)

--- Recursively decompose the call graph on `fs` by repeatedly removing
--- the highest-`inlineScore` member of each cycle (as reported by
--- `Data.SCC.scc`, recomputed on what's left after each removal) until
--- every remaining component is acyclic. Returns the functions that are
--- safe to inline and the ones chosen as loop breakers, each in no
--- particular order.
-- One equation dispatching via `case` (rather than two top-level
-- equations, which the compiler can't always prove are mutually
-- exclusive) to stay deterministic.
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

--- A rough estimate of how expensive inlining this function's body would
--- be: bigger for control-flow-heavy shapes (`Case`/`Or`), smaller for
--- data construction. Used only to pick the "worst" (priciest) member of
--- a recursive group as its loop breaker.
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

