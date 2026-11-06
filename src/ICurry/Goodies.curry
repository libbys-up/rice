----------------------------------------------------------------------------
--- This library provides selector functions, test and update operations
--- as well as some useful auxiliary functions for ICurry data terms,
--- modeled after the conventions of `FlatCurry.Goodies`. Most of the
--- provided functions are based on general transformation functions
--- (`trIProg`, `trIFunction`, `trIExpr`, ...) that replace constructors
--- with user-defined functions, so specific transformations over ICurry
--- terms can be implemented without restating the recursion by hand.
---
--- Domain-specific helpers for Rice's own transformations (boxed literal
--- cases, string-typed pretty-printing helpers, etc.) live in
--- `ICurry.Transforms` instead of here.
----------------------------------------------------------------------------

module ICurry.Goodies where

import ICurry.Types

type Update a b = (b -> b) -> a -> a

-- IProg -----------------------------------------------------------------

--- transform an ICurry program
trIProg :: (String -> [String] -> [IDataType] -> [IFunction] -> a)
           -> IProg -> a
trIProg prog (IProg name imps types funcs) = prog name imps types funcs

-- Selectors

--- get the name of an ICurry program
iProgName :: IProg -> String
iProgName = trIProg (\name _ _ _ -> name)

--- get the imports of an ICurry program
iProgImports :: IProg -> [String]
iProgImports = trIProg (\_ imps _ _ -> imps)

--- get the data type declarations of an ICurry program
iProgDataTypes :: IProg -> [IDataType]
iProgDataTypes = trIProg (\_ _ types _ -> types)

--- get the function declarations of an ICurry program
iProgFuncs :: IProg -> [IFunction]
iProgFuncs = trIProg (\_ _ _ funcs -> funcs)

-- Update Operations

--- update an ICurry program
updIProg :: (String -> String)         ->
            ([String] -> [String])     ->
            ([IDataType] -> [IDataType]) ->
            ([IFunction] -> [IFunction]) -> IProg -> IProg
updIProg fn fi ft ff = trIProg prog
 where
  prog name imps types funcs
    = IProg (fn name) (fi imps) (ft types) (ff funcs)

--- update the name of an ICurry program
updIProgName :: Update IProg String
updIProgName f = updIProg f id id id

--- update the imports of an ICurry program
updIProgImports :: Update IProg [String]
updIProgImports f = updIProg id f id id

--- update the data type declarations of an ICurry program
updIProgDataTypes :: Update IProg [IDataType]
updIProgDataTypes f = updIProg id id f id

--- update the function declarations of an ICurry program
updIProgFuncs :: Update IProg [IFunction]
updIProgFuncs = updIProg id id id

-- Auxiliary Functions

--- get all variables occurring in an ICurry program
allVarsInIProg :: IProg -> [IVarIndex]
allVarsInIProg = concatMap allVarsInIFunc . iProgFuncs

--- update all qualified names in an ICurry program
updQNamesInIProg :: Update IProg IQName
updQNamesInIProg f = updIProg id id
  (map (updQNamesInIDataType f)) (map (updQNamesInIFunc f))

--- rename an ICurry program (updates its name and all qualified names
--- referring to its own module)
rnmIProg :: String -> IProg -> IProg
rnmIProg name p = updIProgName (const name) (updQNamesInIProg rnm p)
 where
  rnm (m,n,i) | m == iProgName p = (name,n,i)
              | otherwise        = (m,n,i)

-- IDataType ---------------------------------------------------------------

--- transform a data type declaration
trIDataType :: (IQName -> [(IQName,IArity)] -> a) -> IDataType -> a
trIDataType f (IDataType name conss) = f name conss

-- Selectors

--- get the name of a data type declaration
iDataName :: IDataType -> IQName
iDataName = trIDataType (\name _ -> name)

--- get the constructors (with their arities) of a data type declaration
iDataConss :: IDataType -> [(IQName,IArity)]
iDataConss = trIDataType (\_ conss -> conss)

-- Update Operations

--- update a data type declaration
updIDataType :: (IQName -> IQName) ->
                ([(IQName,IArity)] -> [(IQName,IArity)]) ->
                IDataType -> IDataType
updIDataType fn fc = trIDataType dt
 where
  dt name conss = IDataType (fn name) (fc conss)

--- update the name of a data type declaration
updIDataName :: Update IDataType IQName
updIDataName f = updIDataType f id

--- update the constructors of a data type declaration
updIDataConss :: Update IDataType [(IQName,IArity)]
updIDataConss = updIDataType id

-- Auxiliary Functions

--- update all qualified names in a data type declaration (both the type's
--- own name and the names of its constructors)
updQNamesInIDataType :: Update IDataType IQName
updQNamesInIDataType f = updIDataType f (map (\(n,a) -> (f n, a)))

-- IFunction -----------------------------------------------------------------

--- transform a function declaration
trIFunction :: (IQName -> IArity -> IVisibility -> [Int] -> IFuncBody -> a)
               -> IFunction -> a
trIFunction f (IFunction name arity vis dem body) = f name arity vis dem body

-- Selectors

--- get the name of a function
iFuncName :: IFunction -> IQName
iFuncName = trIFunction (\name _ _ _ _ -> name)

--- get the arity of a function
iFuncArity :: IFunction -> IArity
iFuncArity = trIFunction (\_ arity _ _ _ -> arity)

--- get the visibility of a function
iFuncVisibility :: IFunction -> IVisibility
iFuncVisibility = trIFunction (\_ _ vis _ _ -> vis)

--- get the positions of always demanded arguments of a function
iFuncDemandedArgs :: IFunction -> [Int]
iFuncDemandedArgs = trIFunction (\_ _ _ dem _ -> dem)

--- get the body of a function
iFuncBody :: IFunction -> IFuncBody
iFuncBody = trIFunction (\_ _ _ _ body -> body)

-- Test Operations

--- is a function externally defined?
isIFuncExternal :: IFunction -> Bool
isIFuncExternal = isIExternalBody . iFuncBody

-- Update Operations

--- update a function declaration
updIFunction :: (IQName -> IQName) ->
                 (IArity -> IArity) ->
                 (IVisibility -> IVisibility) ->
                 ([Int] -> [Int]) ->
                 (IFuncBody -> IFuncBody) -> IFunction -> IFunction
updIFunction fn fa fv fd fb = trIFunction func
 where
  func name arity vis dem body
    = IFunction (fn name) (fa arity) (fv vis) (fd dem) (fb body)

--- update the name of a function
updIFuncName :: Update IFunction IQName
updIFuncName f = updIFunction f id id id id

--- update the arity of a function
updIFuncArity :: Update IFunction IArity
updIFuncArity f = updIFunction id f id id id

--- update the visibility of a function
updIFuncVisibility :: Update IFunction IVisibility
updIFuncVisibility f = updIFunction id id f id id

--- update the demanded-argument positions of a function
updIFuncDemandedArgs :: Update IFunction [Int]
updIFuncDemandedArgs f = updIFunction id id id f id

--- update the body of a function
updIFuncBody :: Update IFunction IFuncBody
updIFuncBody = updIFunction id id id id

-- Auxiliary Functions

--- get all variables occurring in a function's body
allVarsInIFunc :: IFunction -> [IVarIndex]
allVarsInIFunc = allVarsInIFuncBody . iFuncBody

--- update all qualified names in a function
updQNamesInIFunc :: Update IFunction IQName
updQNamesInIFunc f = updIFunction f id id id (updQNamesInIFuncBody f)

--- rename all variables in a function's body
rnmAllVarsInIFunc :: (IVarIndex -> IVarIndex) -> IFunction -> IFunction
rnmAllVarsInIFunc f = updIFuncBody (rnmAllVarsInIFuncBody f)

-- IVisibility -----------------------------------------------------------

-- Test Operations

--- is the visibility public?
isIPublic :: IVisibility -> Bool
isIPublic Public  = True
isIPublic Private = False

--- is the visibility private?
isIPrivate :: IVisibility -> Bool
isIPrivate = not . isIPublic

-- IFuncBody -----------------------------------------------------------------

--- transform a function body
trIFuncBody :: (String -> a) -> (IBlock -> a) -> IFuncBody -> a
trIFuncBody ext _   (IExternal s) = ext s
trIFuncBody _   blk (IFuncBody b) = blk b

-- Selectors

--- get the external name of an externally defined function body
iExternalName :: IFuncBody -> String
iExternalName = trIFuncBody id failed

--- get the block of a non-external function body
iBodyBlock :: IFuncBody -> IBlock
iBodyBlock = trIFuncBody failed id

-- Test Operations

--- is a function body externally defined?
isIExternalBody :: IFuncBody -> Bool
isIExternalBody = trIFuncBody (const True) (const False)

-- Update Operations

--- update the external name of an externally defined function body
updIExternalName :: Update IFuncBody String
updIExternalName f = trIFuncBody (IExternal . f) IFuncBody

--- update the block of a non-external function body
updIBodyBlock :: Update IFuncBody IBlock
updIBodyBlock f = trIFuncBody IExternal (IFuncBody . f)

-- Auxiliary Functions

--- get all variables occurring in a function body
allVarsInIFuncBody :: IFuncBody -> [IVarIndex]
allVarsInIFuncBody = trIFuncBody (const []) allVarsInIBlock

--- update all qualified names in a function body
updQNamesInIFuncBody :: Update IFuncBody IQName
updQNamesInIFuncBody f = updIBodyBlock (updQNamesInIBlock f)

--- rename all variables in a function body
rnmAllVarsInIFuncBody :: (IVarIndex -> IVarIndex) -> IFuncBody -> IFuncBody
rnmAllVarsInIFuncBody f = updIBodyBlock (rnmAllVarsInIBlock f)

-- IBlock ------------------------------------------------------------------

--- transform an ICurry block
trIBlock :: ([IVarDecl] -> [IAssign] -> IStatement -> a) -> IBlock -> a
trIBlock f (IBlock decls asgns stmt) = f decls asgns stmt

-- Selectors

--- get the variable declarations of a block
iBlockVarDecls :: IBlock -> [IVarDecl]
iBlockVarDecls = trIBlock (\decls _ _ -> decls)

--- get the assignments of a block
iBlockAssigns :: IBlock -> [IAssign]
iBlockAssigns = trIBlock (\_ asgns _ -> asgns)

--- get the statement of a block
iBlockStmt :: IBlock -> IStatement
iBlockStmt = trIBlock (\_ _ stmt -> stmt)

-- Update Operations

--- update an ICurry block
updIBlock :: ([IVarDecl] -> [IVarDecl]) ->
             ([IAssign] -> [IAssign])   ->
             (IStatement -> IStatement) -> IBlock -> IBlock
updIBlock fd fa fs = trIBlock blk
 where
  blk decls asgns stmt = IBlock (fd decls) (fa asgns) (fs stmt)

--- update the variable declarations of a block
updIBlockVarDecls :: Update IBlock [IVarDecl]
updIBlockVarDecls f = updIBlock f id id

--- update the assignments of a block
updIBlockAssigns :: Update IBlock [IAssign]
updIBlockAssigns f = updIBlock id f id

--- update the statement of a block
updIBlockStmt :: Update IBlock IStatement
updIBlockStmt = updIBlock id id

-- Auxiliary Functions

--- get all variables occurring in a block (declared, assigned, and used)
allVarsInIBlock :: IBlock -> [IVarIndex]
allVarsInIBlock blk = map iVarDeclIndex (iBlockVarDecls blk) ++
                      concatMap allVarsInIAssign (iBlockAssigns blk) ++
                      allVarsInIStmt (iBlockStmt blk)

--- update all qualified names in a block
updQNamesInIBlock :: Update IBlock IQName
updQNamesInIBlock f
  = updIBlock id (map (updQNamesInIAssign f)) (updQNamesInIStmt f)

--- rename all variables in a block
rnmAllVarsInIBlock :: (IVarIndex -> IVarIndex) -> IBlock -> IBlock
rnmAllVarsInIBlock f = updIBlock (map (updIVarDecl f f))
                                 (map (rnmAllVarsInIAssign f))
                                 (rnmAllVarsInIStmt f)

-- IVarDecl ------------------------------------------------------------------

--- transform a variable declaration
trIVarDecl :: (IVarIndex -> a) -> (IVarIndex -> a) -> IVarDecl -> a
trIVarDecl fv _  (IVarDecl  v) = fv v
trIVarDecl _  ff (IFreeDecl v) = ff v

-- Selectors

--- get the variable index of a variable declaration
iVarDeclIndex :: IVarDecl -> IVarIndex
iVarDeclIndex = trIVarDecl id id

-- Test Operations

--- is this a declaration of a local variable?
isIVarDecl :: IVarDecl -> Bool
isIVarDecl = trIVarDecl (const True) (const False)

--- is this a declaration of a free variable?
isIFreeDecl :: IVarDecl -> Bool
isIFreeDecl = trIVarDecl (const False) (const True)

-- Update Operations

--- update a variable declaration
updIVarDecl :: (IVarIndex -> IVarIndex) -> (IVarIndex -> IVarIndex) ->
               IVarDecl -> IVarDecl
updIVarDecl fv ff = trIVarDecl (IVarDecl . fv) (IFreeDecl . ff)

-- IAssign -------------------------------------------------------------------

--- transform an assignment
trIAssign :: (IVarIndex -> IExpr -> a) ->
             (IVarIndex -> [Int] -> IExpr -> a) -> IAssign -> a
trIAssign fv _  (IVarAssign  v e)   = fv v e
trIAssign _  fn (INodeAssign v p e) = fn v p e

-- Selectors

--- get the assigned-to variable of an assignment
iAssignVar :: IAssign -> IVarIndex
iAssignVar = trIAssign (\v _ -> v) (\v _ _ -> v)

--- get the access path of an assignment (the empty path for a plain
--- variable assignment, i.e. the assignment targets the variable itself)
iAssignPath :: IAssign -> [Int]
iAssignPath = trIAssign (\_ _ -> []) (\_ p _ -> p)

--- get the assigned expression of an assignment
iAssignExpr :: IAssign -> IExpr
iAssignExpr = trIAssign (\_ e -> e) (\_ _ e -> e)

-- Test Operations

--- is this an assignment to a local variable (as opposed to a successor
--- of a node)?
isIVarAssign :: IAssign -> Bool
isIVarAssign = trIAssign (\_ _ -> True) (\_ _ _ -> False)

--- is this an assignment to a successor of a node?
isINodeAssign :: IAssign -> Bool
isINodeAssign = trIAssign (\_ _ -> False) (\_ _ _ -> True)

-- Update Operations

--- update an assignment
updIAssign :: (IVarIndex -> IVarIndex) -> ([Int] -> [Int]) ->
              (IExpr -> IExpr) -> IAssign -> IAssign
updIAssign fv fp fe = trIAssign va na
 where
  va v e   = IVarAssign  (fv v) (fe e)
  na v p e = INodeAssign (fv v) (fp p) (fe e)

--- update the assigned-to variable of an assignment
updIAssignVar :: Update IAssign IVarIndex
updIAssignVar f = updIAssign f id id

--- update the access path of an assignment
updIAssignPath :: Update IAssign [Int]
updIAssignPath f = updIAssign id f id

--- update the assigned expression of an assignment
updIAssignExpr :: Update IAssign IExpr
updIAssignExpr = updIAssign id id

-- Auxiliary Functions

--- get all variables occurring in an assignment
allVarsInIAssign :: IAssign -> [IVarIndex]
allVarsInIAssign a = iAssignVar a : allVarsInIExpr (iAssignExpr a)

--- update all qualified names in an assignment
updQNamesInIAssign :: Update IAssign IQName
updQNamesInIAssign f = updIAssignExpr (updQNamesInIExpr f)

--- rename all variables in an assignment
rnmAllVarsInIAssign :: (IVarIndex -> IVarIndex) -> IAssign -> IAssign
rnmAllVarsInIAssign f = updIAssign f id (rnmAllVarsInIExpr f)

-- IStatement ----------------------------------------------------------------

--- transform a statement
trIStatement :: a ->
                (IExpr -> a) ->
                (IVarIndex -> [IConsBranch] -> a) ->
                (IVarIndex -> [ILitBranch] -> a) -> IStatement -> a
trIStatement exempt _   _   _   IExempt          = exempt
trIStatement _      ret _   _   (IReturn e)      = ret e
trIStatement _      _   cas _   (ICaseCons v bs) = cas v bs
trIStatement _      _   _   lit (ICaseLit  v bs) = lit v bs

-- Selectors

--- get the returned expression of a return statement
iReturnExpr :: IStatement -> IExpr
iReturnExpr = trIStatement failed id (\_ _ -> failed) (\_ _ -> failed)

--- get the scrutinee variable of a case statement (constructor or literal)
iCaseVar :: IStatement -> IVarIndex
iCaseVar = trIStatement failed (const failed) (\v _ -> v) (\v _ -> v)

--- get the branches of a constructor case statement
iConsBranches :: IStatement -> [IConsBranch]
iConsBranches = trIStatement failed (const failed) (\_ bs -> bs) (\_ _ -> failed)

--- get the branches of a literal case statement
iLitBranches :: IStatement -> [ILitBranch]
iLitBranches = trIStatement failed (const failed) (\_ _ -> failed) (\_ bs -> bs)

-- Test Operations

--- is this a failure statement?
isIExempt :: IStatement -> Bool
isIExempt s = case s of IExempt -> True; _ -> False

--- is this a return statement?
isIReturn :: IStatement -> Bool
isIReturn s = case s of IReturn _ -> True; _ -> False

--- is this a case statement over constructors?
isICaseCons :: IStatement -> Bool
isICaseCons s = case s of ICaseCons _ _ -> True; _ -> False

--- is this a case statement over literals?
isICaseLit :: IStatement -> Bool
isICaseLit s = case s of ICaseLit _ _ -> True; _ -> False

--- is this a case statement (over constructors or literals)?
isICase :: IStatement -> Bool
isICase s = isICaseCons s || isICaseLit s

-- Update Operations

--- update a statement
updIStatement :: (IExpr -> IExpr) ->
                  (IVarIndex -> IVarIndex) ->
                  ([IConsBranch] -> [IConsBranch]) ->
                  (IVarIndex -> IVarIndex) ->
                  ([ILitBranch] -> [ILitBranch]) -> IStatement -> IStatement
updIStatement fe fcv fcb flv flb = trIStatement IExempt ret cas lit
 where
  ret e    = IReturn (fe e)
  cas v bs = ICaseCons (fcv v) (fcb bs)
  lit v bs = ICaseLit  (flv v) (flb bs)

--- update the returned expression of a return statement
updIReturnExpr :: Update IStatement IExpr
updIReturnExpr f = updIStatement f id id id id

--- update the scrutinee variable of a case statement (constructor or
--- literal, whichever the statement actually is)
updICaseVar :: Update IStatement IVarIndex
updICaseVar f = updIStatement id f id f id

--- update the branches of a constructor case statement
updIConsBranches :: Update IStatement [IConsBranch]
updIConsBranches f = updIStatement id id f id id

--- update the branches of a literal case statement
updILitBranches :: Update IStatement [ILitBranch]
updILitBranches f = updIStatement id id id id f

-- Auxiliary Functions

--- get all variables occurring in a statement
allVarsInIStmt :: IStatement -> [IVarIndex]
allVarsInIStmt = trIStatement [] allVarsInIExpr cas lit
 where
  cas v bs = v : concatMap allVarsInIConsBranch bs
  lit v bs = v : concatMap allVarsInILitBranch  bs

--- update all qualified names in a statement
updQNamesInIStmt :: Update IStatement IQName
updQNamesInIStmt f = updIStatement (updQNamesInIExpr f) id
                                    (map (updQNamesInIConsBranch f)) id
                                    (map (updILitBranchBlock (updQNamesInIBlock f)))

--- rename all variables in a statement
rnmAllVarsInIStmt :: (IVarIndex -> IVarIndex) -> IStatement -> IStatement
rnmAllVarsInIStmt f = updIStatement (rnmAllVarsInIExpr f) f
                                     (map (rnmAllVarsInIConsBranch f)) f
                                     (map (rnmAllVarsInILitBranch f))

-- IConsBranch -----------------------------------------------------------

--- transform a constructor branch
trIConsBranch :: (IQName -> IArity -> IBlock -> a) -> IConsBranch -> a
trIConsBranch f (IConsBranch name arity blk) = f name arity blk

-- Selectors

--- get the constructor name of a constructor branch
iConsBranchName :: IConsBranch -> IQName
iConsBranchName = trIConsBranch (\name _ _ -> name)

--- get the constructor arity of a constructor branch
iConsBranchArity :: IConsBranch -> IArity
iConsBranchArity = trIConsBranch (\_ arity _ -> arity)

--- get the block of a constructor branch
iConsBranchBlock :: IConsBranch -> IBlock
iConsBranchBlock = trIConsBranch (\_ _ blk -> blk)

-- Update Operations

--- update a constructor branch
updIConsBranch :: (IQName -> IQName) -> (IArity -> IArity) ->
                   (IBlock -> IBlock) -> IConsBranch -> IConsBranch
updIConsBranch fn fa fb = trIConsBranch branch
 where
  branch name arity blk = IConsBranch (fn name) (fa arity) (fb blk)

--- update the constructor name of a constructor branch
updIConsBranchName :: Update IConsBranch IQName
updIConsBranchName f = updIConsBranch f id id

--- update the constructor arity of a constructor branch
updIConsBranchArity :: Update IConsBranch IArity
updIConsBranchArity f = updIConsBranch id f id

--- update the block of a constructor branch
updIConsBranchBlock :: Update IConsBranch IBlock
updIConsBranchBlock = updIConsBranch id id

-- Auxiliary Functions

--- get all variables occurring in a constructor branch
allVarsInIConsBranch :: IConsBranch -> [IVarIndex]
allVarsInIConsBranch = allVarsInIBlock . iConsBranchBlock

--- update all qualified names in a constructor branch
updQNamesInIConsBranch :: Update IConsBranch IQName
updQNamesInIConsBranch f = updIConsBranch f id (updQNamesInIBlock f)

--- rename all variables in a constructor branch
rnmAllVarsInIConsBranch :: (IVarIndex -> IVarIndex) ->
                           IConsBranch -> IConsBranch
rnmAllVarsInIConsBranch f = updIConsBranchBlock (rnmAllVarsInIBlock f)

-- ILitBranch ------------------------------------------------------------

--- transform a literal branch
trILitBranch :: (ILiteral -> IBlock -> a) -> ILitBranch -> a
trILitBranch f (ILitBranch lit blk) = f lit blk

-- Selectors

--- get the literal of a literal branch
iLitBranchLiteral :: ILitBranch -> ILiteral
iLitBranchLiteral = trILitBranch (\lit _ -> lit)

--- get the block of a literal branch
iLitBranchBlock :: ILitBranch -> IBlock
iLitBranchBlock = trILitBranch (\_ blk -> blk)

-- Update Operations

--- update a literal branch
updILitBranch :: (ILiteral -> ILiteral) -> (IBlock -> IBlock) ->
                  ILitBranch -> ILitBranch
updILitBranch fl fb = trILitBranch branch
 where
  branch lit blk = ILitBranch (fl lit) (fb blk)

--- update the literal of a literal branch
updILitBranchLiteral :: Update ILitBranch ILiteral
updILitBranchLiteral f = updILitBranch f id

--- update the block of a literal branch
updILitBranchBlock :: Update ILitBranch IBlock
updILitBranchBlock = updILitBranch id

-- Auxiliary Functions

--- get all variables occurring in a literal branch
allVarsInILitBranch :: ILitBranch -> [IVarIndex]
allVarsInILitBranch = allVarsInIBlock . iLitBranchBlock

--- rename all variables in a literal branch (literal branches carry no
--- qualified names, so there is no updQNamesInILitBranch)
rnmAllVarsInILitBranch :: (IVarIndex -> IVarIndex) -> ILitBranch -> ILitBranch
rnmAllVarsInILitBranch f = updILitBranchBlock (rnmAllVarsInIBlock f)

-- IExpr -----------------------------------------------------------------

-- Selectors

--- get the variable index of a variable expression
iVarNr :: IExpr -> IVarIndex
iVarNr e = case e of
  IVar v -> v
  _      -> error "ICurry.Goodies.iVarNr: no variable"

--- get the variable index of a variable-access expression
iVarAccessNr :: IExpr -> IVarIndex
iVarAccessNr e = case e of
  IVarAccess v _ -> v
  _              -> error "ICurry.Goodies.iVarAccessNr: no variable access"

--- get the access path of a variable-access expression
iVarAccessPath :: IExpr -> [Int]
iVarAccessPath e = case e of
  IVarAccess _ p -> p
  _              -> error "ICurry.Goodies.iVarAccessPath: no variable access"

--- get the literal of a literal expression
iExprLiteral :: IExpr -> ILiteral
iExprLiteral e = case e of
  ILit l -> l
  _      -> error "ICurry.Goodies.iExprLiteral: no literal"

--- get the name of a call expression (function or constructor, full or
--- partial)
iCallQName :: IExpr -> IQName
iCallQName e = case e of
  IFCall  n _   -> n
  ICCall  n _   -> n
  IFPCall n _ _ -> n
  ICPCall n _ _ -> n
  _             -> error "ICurry.Goodies.iCallQName: no call expression"

--- get the arguments of a call expression
iCallArgs :: IExpr -> [IExpr]
iCallArgs e = case e of
  IFCall  _ es   -> es
  ICCall  _ es   -> es
  IFPCall _ _ es -> es
  ICPCall _ _ es -> es
  _              -> error "ICurry.Goodies.iCallArgs: no call expression"

--- get the number of missing arguments of a partial call expression
iCallMissing :: IExpr -> Int
iCallMissing e = case e of
  IFPCall _ m _ -> m
  ICPCall _ m _ -> m
  _             -> error "ICurry.Goodies.iCallMissing: not a partial call"

--- get the two alternatives of an or-expression
iOrExps :: IExpr -> [IExpr]
iOrExps e = case e of
  IOr e1 e2 -> [e1,e2]
  _         -> error "ICurry.Goodies.iOrExps: no or-expression"

-- Test Operations

--- is the expression a variable?
isIVar :: IExpr -> Bool
isIVar e = case e of IVar _ -> True; _ -> False

--- is the expression a variable access?
isIVarAccess :: IExpr -> Bool
isIVarAccess e = case e of IVarAccess _ _ -> True; _ -> False

--- is the expression a literal?
isILit :: IExpr -> Bool
isILit e = case e of ILit _ -> True; _ -> False

--- is the expression a full function call?
isIFCall :: IExpr -> Bool
isIFCall e = case e of IFCall _ _ -> True; _ -> False

--- is the expression a full constructor call?
isICCall :: IExpr -> Bool
isICCall e = case e of ICCall _ _ -> True; _ -> False

--- is the expression a partial function call?
isIFPCall :: IExpr -> Bool
isIFPCall e = case e of IFPCall _ _ _ -> True; _ -> False

--- is the expression a partial constructor call?
isICPCall :: IExpr -> Bool
isICPCall e = case e of ICPCall _ _ _ -> True; _ -> False

--- is the expression an or-expression?
isIOr :: IExpr -> Bool
isIOr e = case e of IOr _ _ -> True; _ -> False

--- is the expression a call (function or constructor, full or partial)?
isICall :: IExpr -> Bool
isICall e = isIFCall e || isICCall e || isIFPCall e || isICPCall e

--- is the expression a partial call (function or constructor)?
isIPartCall :: IExpr -> Bool
isIPartCall e = isIFPCall e || isICPCall e

--- transform an expression
trIExpr :: (IVarIndex -> a) ->
           (IVarIndex -> [Int] -> a) ->
           (ILiteral -> a) ->
           (IQName -> [a] -> a) ->
           (IQName -> [a] -> a) ->
           (IQName -> Int -> [a] -> a) ->
           (IQName -> Int -> [a] -> a) ->
           (a -> a -> a) ->
           IExpr -> a
trIExpr var _ _ _ _ _ _ _ (IVar v) = var v

trIExpr _ vacc _ _ _ _ _ _ (IVarAccess v p) = vacc v p

trIExpr _ _ lit _ _ _ _ _ (ILit l) = lit l

trIExpr var vacc lit fcall ccall fpcall cpcall orr (IFCall n es)
  = fcall n (map f es)
 where
  f = trIExpr var vacc lit fcall ccall fpcall cpcall orr

trIExpr var vacc lit fcall ccall fpcall cpcall orr (ICCall n es)
  = ccall n (map f es)
 where
  f = trIExpr var vacc lit fcall ccall fpcall cpcall orr

trIExpr var vacc lit fcall ccall fpcall cpcall orr (IFPCall n m es)
  = fpcall n m (map f es)
 where
  f = trIExpr var vacc lit fcall ccall fpcall cpcall orr

trIExpr var vacc lit fcall ccall fpcall cpcall orr (ICPCall n m es)
  = cpcall n m (map f es)
 where
  f = trIExpr var vacc lit fcall ccall fpcall cpcall orr

trIExpr var vacc lit fcall ccall fpcall cpcall orr (IOr e1 e2)
  = orr (f e1) (f e2)
 where
  f = trIExpr var vacc lit fcall ccall fpcall cpcall orr

-- Update Operations

--- update all variables in an expression
updIVars :: (IVarIndex -> IExpr) -> IExpr -> IExpr
updIVars fvar = trIExpr fvar IVarAccess ILit IFCall ICCall IFPCall ICPCall IOr

--- update all variable accesses in an expression
updIVarAccesses :: (IVarIndex -> [Int] -> IExpr) -> IExpr -> IExpr
updIVarAccesses fvacc
  = trIExpr IVar fvacc ILit IFCall ICCall IFPCall ICPCall IOr

--- update all literals in an expression
updILiterals :: (ILiteral -> IExpr) -> IExpr -> IExpr
updILiterals flit
  = trIExpr IVar IVarAccess flit IFCall ICCall IFPCall ICPCall IOr

--- update all full function calls in an expression
updIFCalls :: (IQName -> [IExpr] -> IExpr) -> IExpr -> IExpr
updIFCalls ffcall
  = trIExpr IVar IVarAccess ILit ffcall ICCall IFPCall ICPCall IOr

--- update all full constructor calls in an expression
updICCalls :: (IQName -> [IExpr] -> IExpr) -> IExpr -> IExpr
updICCalls fccall
  = trIExpr IVar IVarAccess ILit IFCall fccall IFPCall ICPCall IOr

--- update all partial function calls in an expression
updIFPCalls :: (IQName -> Int -> [IExpr] -> IExpr) -> IExpr -> IExpr
updIFPCalls ffpcall
  = trIExpr IVar IVarAccess ILit IFCall ICCall ffpcall ICPCall IOr

--- update all partial constructor calls in an expression
updICPCalls :: (IQName -> Int -> [IExpr] -> IExpr) -> IExpr -> IExpr
updICPCalls fcpcall
  = trIExpr IVar IVarAccess ILit IFCall ICCall IFPCall fcpcall IOr

--- update all or-expressions in an expression
updIOrs :: (IExpr -> IExpr -> IExpr) -> IExpr -> IExpr
updIOrs for = trIExpr IVar IVarAccess ILit IFCall ICCall IFPCall ICPCall for

-- Auxiliary Functions

--- get all variables (including those only accessed, not just bound) in
--- an expression
allVarsInIExpr :: IExpr -> [IVarIndex]
allVarsInIExpr e = trIExpr var vacc lit call call callm callm orr e []
 where
  var v          = (v:)
  vacc v _       = (v:)
  lit _          = id
  call _ as      = foldr (.) id as
  callm _ _ as   = foldr (.) id as
  orr            = (.)

--- update all qualified names in an expression
updQNamesInIExpr :: Update IExpr IQName
updQNamesInIExpr f
  = trIExpr IVar IVarAccess ILit fcall ccall fpcall cpcall IOr
 where
  fcall  n args   = IFCall  (f n) args
  ccall  n args   = ICCall  (f n) args
  fpcall n m args = IFPCall (f n) m args
  cpcall n m args = ICPCall (f n) m args

--- rename all variables in an expression
rnmAllVarsInIExpr :: (IVarIndex -> IVarIndex) -> IExpr -> IExpr
rnmAllVarsInIExpr f
  = trIExpr (IVar . f) (\v p -> IVarAccess (f v) p) ILit
            IFCall ICCall IFPCall ICPCall IOr

-- ILiteral --------------------------------------------------------------

--- transform a literal
trILiteral :: (Int -> a) -> (Char -> a) -> (Float -> a) -> ILiteral -> a
trILiteral fi _  _  (IInt   n) = fi n
trILiteral _  fc _  (IChar  c) = fc c
trILiteral _  _  ff (IFloat x) = ff x

-- Selectors

--- get the value of an integer literal
iIntValue :: ILiteral -> Int
iIntValue = trILiteral id failed failed

--- get the value of a character literal
iCharValue :: ILiteral -> Char
iCharValue = trILiteral failed id failed

--- get the value of a float literal
iFloatValue :: ILiteral -> Float
iFloatValue = trILiteral failed failed id

-- Test Operations

--- is the literal an integer literal?
isIInt :: ILiteral -> Bool
isIInt = trILiteral (const True) (const False) (const False)

--- is the literal a character literal?
isIChar :: ILiteral -> Bool
isIChar = trILiteral (const False) (const True) (const False)

--- is the literal a float literal?
isIFloat :: ILiteral -> Bool
isIFloat = trILiteral (const False) (const False) (const True)

-- Update Operations

--- update a literal
updILiteral :: (Int -> Int) -> (Char -> Char) -> (Float -> Float) ->
               ILiteral -> ILiteral
updILiteral fi fc ff = trILiteral (IInt . fi) (IChar . fc) (IFloat . ff)
