

module Rice.Transform.ANF (normalize, normalizeTExpr) where

import Control.Monad.Trans.State
import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies (updTProgTExps)
import Data.List (maximum)
import Rice.Util (fresh, newVar)

--    $$
--    \begin{array}{lcl}
--    \mathcal{E} & = & \square \\
--                & | & \textbf{let}~x~\mathcal{E}~\textbf{in}~M \\
--                & | & \textbf{case}~\mathcal{E}~\textbf{of}~
--                                    (P~\texttt{->}~M)^* \\
--                & | & F~V\ldots V~\mathcal{E}~M\ldots M\\
--                & | & \mathcal{E} ? M\\
--                & | & M ? \mathcal{E}
--    \end{array}
--    $$\\
--    $$
--    \begin{array}{lcl}
--     \mathcal{E}[\textbf{let}~x = M~\textbf{in}~N] & \rightarrow &
--      \textbf{let}~x = M~\textbf{in}~\mathcal{E}[N]\\
--        \mathcal{E}[\textbf{case}~V~\textbf{of}~(P~\texttt{->}~M)^*] 
--        & \rightarrow & 
--        \textbf{case}~V~\textbf{of}~(P~\texttt{->}~\mathcal{E}[M])^*\\
--     \mathcal{E}[F~V^*] & \rightarrow &
--        \textbf{let}~t = F~V^*~\textbf{in}~\mathcal{E}[t] \\
--     \mathcal{E}[V_1 ? V_2] & \rightarrow &
--        \textbf{let}~t = V_1 ? V_2~\textbf{in}~\mathcal{E}[t] \\
--    \end{array}
--        $$
--    \caption{A-Normal form transformation}
--    \ref{fig:anf}

type VState e = State VarIndex e

pair :: a -> b -> (a,b)
pair x y = (x,y)

normalize :: TProg -> TProg
normalize = updTProgTExps normalizeTExpr

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
