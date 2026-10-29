------------------------------------------------------------------------------
--- A-normal form: every argument of a call or constructor, every case
--- scrutinee and every choice alternative becomes a variable or literal,
--- with `let`s for everything else. ICurry generation and the field reps
--- both rely on this. The rewrite rules, for an evaluation context E:
---
---   E[let x = M in N]          ->  let x = M in E[N]
---   E[case V of P -> M ...]    ->  case V of P -> E[M] ...
---   E[F V...]                  ->  let t = F V... in E[t]
---   E[V1 ? V2]                 ->  let t = V1 ? V2 in E[t]
---
--- where E is a hole, `let x = E in M`, `case E of ...`, `F V...V E M...M`,
--- `E ? M` or `M ? E`. `anf` is written in continuation passing style:
--- `k` builds the context around the normalized expression.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Transform.ANF (normalize, normalizeTExpr) where

import Control.Monad.Trans.State
import FlatCurry.Typed.Types
import Data.List (maximum)
import Rice.Util (fresh, newVar, updProgFresh)

type VState e = State VarIndex e

pair :: a -> b -> (a,b)
pair x y = (x,y)

normalize :: TProg -> TProg
normalize = updProgFresh (\e -> anf e return)

normalizeTExpr :: TExpr -> TExpr
normalizeTExpr e = evalState (anf e return) (newVar e)

anf :: TExpr -> (TExpr -> VState TExpr) -> VState TExpr
anf v@(TVarE _ _)     k = k v
anf l@(TLit _ _)      k = k l
anf (TFree vs e)      k = TFree vs <$> (anf e k)
anf (TTyped e t)      k = anf e (\v -> k (TTyped v t))
anf (TOr e1 e2)       k = anfName e1 (\v1 -> anfName e2 (k . TOr v1))
anf (TLet ls e)       k = do ls' <- mapM anfLet ls
                             TLet ls' <$> anfName e k
anf (TCase ct e bs)   k = do bs' <- mapM anfBranch bs
                             anfName e  (\v -> k (TCase ct v bs'))
anf (TComb t ct n es) k = anfArgs es (\vs -> k (TComb t ct n vs))
 where anfArgs []     k = k []
       anfArgs (e:es) k = anfName e (\v -> anfArgs es (\vs -> k (v:vs)))

anfLet :: ((VarIndex,TypeExpr),TExpr) -> VState ((VarIndex,TypeExpr),TExpr)
anfLet (v,e) = pair v <$> anf e return

anfBranch :: TBranchExpr -> VState TBranchExpr
anfBranch (TBranch p e) = TBranch p <$> anf e return

anfName :: TExpr -> (TExpr -> VState TExpr) -> VState TExpr
anfName e k = anf e addLet
 where addLet :: TExpr -> VState TExpr
       addLet v
        | value v = k v
        | otherwise = do x <- fresh
                         let t = typeOf e
                         TLet [((x, t), v)] <$> k (TVarE t x)

value :: TExpr -> Bool
value (TVarE _ _)     = True
value (TLit _ _)      = True
value (TLet _ _)      = False
value (TOr _ _)       = False
value (TFree _ _)     = False
value (TCase _ _ _)   = False
value (TTyped _ _)    = False
value (TComb _ _ _ _) = False
