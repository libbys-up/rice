module Rice.Transform.Untype (removeTypes) where
import FlatCurry.Types
import FlatCurry.Typed.Types

removeTypes :: TProg -> Prog
removeTypes (TProg name imps types funs ops) =
             Prog name imps types (map removeFunTypes funs) ops

removeFunTypes :: TFuncDecl -> FuncDecl
removeFunTypes (TFunc name arity vis typ rule) =
                Func name arity vis typ (removeRuleTypes rule)

removeRuleTypes :: TRule -> Rule
removeRuleTypes (TRule tvs te)    = Rule (map fst tvs) (removeExprTypes te)
removeRuleTypes (TExternal t ext) = External ext

removeExprTypes :: TExpr -> Expr
removeExprTypes (TVarE  _ v)       = Var v
removeExprTypes (TLit   _ l)       = Lit l
removeExprTypes (TComb  _ ct n es) = Comb ct n (map removeExprTypes es)
removeExprTypes (TLet   vs e)      = Let (map fixLet vs) (removeExprTypes e)
 where fixLet ((v,t),e) = (v,t,removeExprTypes e)
removeExprTypes (TFree  vs e)      = Free vs (removeExprTypes e)
removeExprTypes (TOr    e1 e2)     = Or (removeExprTypes e1) (removeExprTypes e2)
removeExprTypes (TCase  ct e bs)   = Case ct (removeExprTypes e) (map removeBranchTypes bs)
removeExprTypes (TTyped e t)       = Typed (removeExprTypes e) t

removeBranchTypes :: TBranchExpr -> BranchExpr
removeBranchTypes (TBranch pat e) = Branch (removePatternTypes pat) (removeExprTypes e)

removePatternTypes :: TPattern -> Pattern
removePatternTypes (TPattern  _ name vs) = Pattern name (map fst vs)
removePatternTypes (TLPattern _ l)       = LPattern l


