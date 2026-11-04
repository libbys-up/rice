------------------------------------------------------------------------------
--- Merging chains of `let`s, just before ICurry generation.
---
--- A `let` whose body is another `let` becomes one `let` with the bindings
--- of both: `let xs in let ys in e` becomes `let xs ++ ys in e`.
---
--- ICurry generation (`FlatCurry.CaseLifting.liftExp`) lifts a `let`'s body
--- into a new function whenever that body isn't simple, and a nested `let`
--- isn't. The new function takes every variable still live in the body. So
--- a chain of n `let`s, which ANF makes out of any nested term, became n
--- functions, and since a term's subterms are bound early and used only
--- when the whole term is built, about n^2/2 parameters in all
--- (kics2_bench/SatSolver: 2,289 functions, 42 MB of C, over a minute to
--- compile). Merged, the chain is one function, and only a `case` after a
--- `let`, or inside a binding, is lifted.
---
--- The merge is safe because variable indices are unique within a
--- function, so nothing is captured, and the outer bindings never refer to
--- the inner ones. ICurry assigns a `let`'s bindings in order, adding a
--- recursive assignment only for a reference to the same or a later
--- binding, so the merged `let` compiles to the same assignments.
---
--- ANF keeps the `let`s apart, so later optimizations see each binding
--- with its own scope; this pass only changes the shape ICurry sees.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Transform.MergeLets (mergeLets) where

import FlatCurry.Types

--- Merge the `let` chains in every function of a program.
mergeLets :: Prog -> Prog
mergeLets (Prog name imps types funs ops) =
  Prog name imps types (map mergeFunc funs) ops

mergeFunc :: FuncDecl -> FuncDecl
mergeFunc (Func name arity vis typ rule) = Func name arity vis typ rule'
 where rule' = case rule of
                 Rule vs e  -> Rule vs (mergeExpr e)
                 External _ -> rule

mergeExpr :: Expr -> Expr
mergeExpr e = case e of
  Var _          -> e
  Lit _          -> e
  Comb ct n es   -> Comb ct n (map mergeExpr es)
  Let bs body    -> mkLet (map mergeBind bs) (mergeExpr body)
  Free vs body   -> Free vs (mergeExpr body)
  Or e1 e2       -> Or (mergeExpr e1) (mergeExpr e2)
  Case ct s bs   -> Case ct (mergeExpr s) (map mergeBranch bs)
  Typed e' t     -> Typed (mergeExpr e') t
 where
  mergeBind (v, t, b)        = (v, t, mergeExpr b)
  mergeBranch (Branch p b)   = Branch p (mergeExpr b)

--- `let bs in body`, with body's own bindings added if body is a `let`.
--- body is already merged, so it's never a `let` of a `let`.
mkLet :: [(VarIndex, TypeExpr, Expr)] -> Expr -> Expr
mkLet bs body = case body of
  Let bs' e -> Let (bs ++ bs') e
  _         -> Let bs body
