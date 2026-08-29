
module Rice.Transform.Order where

import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies (tFuncName, tBranchTExpr,
                                isCombTypeFuncCall, isCombTypeFuncPartCall)

import Data.SCC (scc)
import Data.List (sortBy)

import Rice.Util

loops :: TProg -> [[String]]
loops (TProg _ _ _ fs _) = (map . map) name $ scc (\x -> [name x]) calls fs

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

