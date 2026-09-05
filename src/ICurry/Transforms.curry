module ICurry.Transforms (iname, isExternal, isVarAsgn,
                       litBlock, litType, litBranchValue,
                       litBranchType, litPatterns, isPrimitive) where

import Rice.Util ((++-), mergeMap)
import ICurry.Types
import Data.List (intercalate, isPrefixOf, splitOn)



-----------------------------------------------
-- general traversal functions
-----------------------------------------------

iname :: IProg -> String
iname (IProg name _ _ _) = name

imports :: IProg -> [String]
imports (IProg _ imps _ _) = imps

dataTypes :: IProg -> [IDataType]
dataTypes (IProg _ _ ts _) = ts

funcs :: IProg -> [IFunction]
funcs (IProg _ _ _ fs) = fs

funcName :: IFunction -> IQName
funcName (IFunction name _ _ _ _) = name

funcArity :: IFunction -> Int
funcArity (IFunction _ arity _ _ _) = arity

funcVis :: IFunction -> IVisibility
funcVis (IFunction _ _ vis _ _) = vis

funcDeps :: IFunction -> [Int]
funcDeps (IFunction _ _ _ deps _) = deps

funcBody :: IFunction -> IFuncBody
funcBody (IFunction _ _ _ _ body) = body

isExternal :: IFuncBody -> Bool
isExternal (IExternal _) = True
isExternal (IFuncBody _) = False

externalFunc :: IFunction -> Bool
externalFunc = isExternal . funcBody

isVarAsgn :: IAssign -> Bool
isVarAsgn (IVarAssign _ _)    = True
isVarAsgn (INodeAssign _ _ _) = False


isVar :: IExpr -> Bool
isVar (IVar _)           = True
isVar (IVarAccess _ _)   = True
isVar (ILit _)           = False
isVar (IOr _ _)          = False
isVar (IFCall _ _)       = False
isVar (ICCall _ _)       = False
isVar (IFPCall _ _ _)    = False
isVar (ICPCall _ _ _)    = False

varFromDecl :: IVarDecl -> IVarIndex
varFromDecl (IVarDecl  v) = v
varFromDecl (IFreeDecl v) = v

varsInStmt :: IStatement -> [IVarIndex]
varsInStmt IExempt          = []
varsInStmt (IReturn e)      = varsInExpr e
varsInStmt (ICaseLit  v bs) = [v] ++- mergeMap varsInLit bs
 where varsInLit (ILitBranch _ b) = varsInBlock b
varsInStmt (ICaseCons v bs) = [v] ++- mergeMap varsInCons bs
 where varsInCons (IConsBranch _ _ b) = varsInBlock b

varsInExpr :: IExpr -> [IVarIndex]
varsInExpr (IVar        v)      = [v]
varsInExpr (IVarAccess  v _)    = [v]
varsInExpr (ILit        _)      = []
varsInExpr (IFCall      _ es)   = mergeMap varsInExpr es
varsInExpr (ICCall      _ es)   = mergeMap varsInExpr es
varsInExpr (IFPCall     _ _ es) = mergeMap varsInExpr es
varsInExpr (ICPCall     _ _ es) = mergeMap varsInExpr es
varsInExpr (IOr         e1 e2)  = varsInExpr e1 ++- varsInExpr e2

varsInBlock :: IBlock -> [IVarIndex]
varsInBlock (IBlock _ as s) = mergeMap varsInAssign as ++-
                              varsInStmt s
 where varsInAssign (IVarAssign _ e)    = varsInExpr e
       varsInAssign (INodeAssign _ _ e) = varsInExpr e

isPrimitive :: [IConsBranch] -> Bool
isPrimitive [] = False
isPrimitive (IConsBranch n _ _ : _) = isPrim n

litPatterns :: [IConsBranch] -> [ILiteral]
litPatterns (_:bs) = map pattern bs
 where pattern (IConsBranch _ _ (IBlock _ _ (IReturn (ILit l)))) = l

litBranchType :: ILitBranch -> String
litBranchType (ILitBranch l _)  = litType l

litBranchValue :: ILitBranch -> String
litBranchValue (ILitBranch (IInt   v) _)  = show v
litBranchValue (ILitBranch (IFloat v) _)  = show v
litBranchValue (ILitBranch (IChar  v) _)  = show v

litType :: ILiteral -> String
litType (IInt   _)  = "int"
litType (IFloat _)  = "float"
litType (IChar  _)  = "char"

litBlock :: ILitBranch -> IBlock
litBlock (ILitBranch _ b)  = b

--------------------------------------------------------------------
-- Code for dealing with boxed literals
--
-- Box literals are going to have the form
-- case v of
--      Int# x -> case x of
--                     v1 -> ...
--                     v2 -> ...
--                     ...
--                     vn -> ...
--      () -> v1
--      () -> v2
--      ...
--      () -> vn
-- where () is IQName ("","",0)
--       v1,v2,...,vn are the literal values in the inner case
--       Int# is IQName ("Prelude","Int#",1)
--       while could be Int#, Char#, or Float#
--
-- The ICurry transformation will have put the inner case in a separate
-- function definition, so we need access to the possible values
-- of free variables, when we unwrap the box.
-- This means that I need them in the outer case.
-- There are probably better ways to do this.
--------------------------------------------------------------------

-- check if a cons case is really unboxing a literal value.
-- If this is the case, then that will change the code I generate for
-- the free branch.
-- Bind each
isPrimCase :: [IConsBranch] -> Bool
isPrimCase []     = False
isPrimCase (b:bs) = isPrim (branchName b) &&
                    all (isDummy . branchName) bs

branchName :: IConsBranch -> IQName
branchName (IConsBranch n _ _) = n

isDummy :: IQName -> Bool
isDummy (q,n,_) = null q && null n

isBox :: IQName -> Bool
isBox (q,n,_) = case (q,n) of
                     ("Prelude","Int") -> True
                     ("Prelude","Float") -> True
                     ("Prelude","Char") -> True
                     _ -> False

isPrim :: IQName -> Bool
isPrim (q,n,_) = case (q,n) of
                      ("Prelude","Int#") -> True
                      ("Prelude","Float#") -> True
                      ("Prelude","Char#") -> True
                      _ -> False

