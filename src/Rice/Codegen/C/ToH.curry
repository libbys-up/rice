module Rice.Codegen.C.ToH (toH) where

import Codegen.C.C
import ICurry.Types
import ICurry.Goodies
import Data.Functional.DList
import Codegen.Names
import Codegen.CodeGen


toH :: IProg -> String -> IO ()
toH ip file = do let ((), dlist) = runWriter (toHeader ip)
                 writeFile file (toList dlist)

toHeader :: IProg -> CodeGen ()
toHeader (IProg name imps types allFuns)
 = do let internal = filter (not . isExternal) allFuns
      let external = filter isExternal allFuns
      makeIntro name imps allFuns
      mapM_ makeTags types 
      writeSymbols types funs
      -- optimization: Don't make multiple copies of constant values.
      -- This is part of the flywheel pattern.
      mapM_ declConstant [n | (IDataType _ cs) <- types, (n,0) <- cs]
      mapM_ setType types
      mapM_ setFun funs
      mapM_ makeType types
      mapM_ makeFun funs
      mapM_ setTypeFree types
      mapM_ makeTypeFree types
      emit $ "#endif //"++name++"_H"

makeIntro :: String -> [String] -> [IFuncDecl] -> CodeGen ()
makeIntro name imps funs
 = do emit $ "#ifndef "++name++"_H"
      emit $ "#define "++name++"_H"
      nl
      cinclude "runtime"
      mapM_ cinclude imps
      nl
      mapM_ declareFun funs
      nl

-- declare the f_hnf functions
declareFun :: IFunction -> CStmt
declareFun (IFunction f _ _ _ _) = cfunDecl "void" (hnf f) [("field", "root")]

-- declare the constants for the flywheel pattern
declConstant :: IQName -> CStmt
declConstant n = emit $ "extern field " ++ mangle n ++ ";\n"


-- #define all of the tages for constructors
makeTags :: IDataType -> CStmt
makeTags (IDataType name constrs)
 = do comment $ "tags for "++name
      mapM_ makeTag constrs
      nl
 where makeTag (n,_) = cdefine (tag n) (getTag n + 5)

---------------------------------------------------------------------
-- Write out the symbol table for each constructor and function
-- The symbol for 
-- q.f :: Int -> Int -> Int
-- will look like
-- static Symbol q_f_symbol = { .tag = "FUNCTION_TAG", 
--                              .arity = 2, 
--                              .name = "q.f", 
--                              .hnf = &q_f_hnf };
--
-- The symbol for 
-- data Maybe a = Nothing | Just a
-- will look like
-- static Symbol Prelude_Nothing_symbol = { .tag = "Prelude_Nothing_TAG",
--                                          .arity = 0,
--                                          .name = "Prelude.Nothing",
--                                          .hnf = &CTR_hnf };
---------------------------------------------------------------------
writeSymbols :: [IDataType] -> [IFunction] -> CodeGen ()
writeSymbols types funs =
 do mapM_ conSymbol [c | t <- types, c <- cons t]
    mapM_ funSymbol funs
    nl
 where
  cons (IDataType _ cs) = cs
  conSymbol (n,a)                 = symbol n (tag n)        a "&CTR_hnf" 
  funSymbol (IFunction n a _ _ _) = symbol n "FUNCTION_TAG" a ("&"++hnf n)
  tag n = mangle n ++ "_TAG"

symbol :: String -> String -> Int -> String -> String -> CStmt
symbol name tag arity hnf 
  = do stmt $ "static Symbol "++ (sym name) .=
                   (carray [ ".tag" .= tag,
                             ".arity" .= show arity,
                             ".name" .= quote (toName name),
                             ".hnf" .= hnf])

--------------------------------------------------------------------
-- set_f functions
-- These overwrite the contents of the root node to match f.
-- q.f :: Int -> Int -> Int
-- will have a set_f function that looks like
-- void set_q_f(field root, field v1, field v2, int missing)
-- {
--     root.n = &q_f_symbol;
--     root.missing = missing;
--     child_at_i(root,0) = v2;
--     child_at_i(root,1) = v1;
--     child_at_i(root,2) = NULL;
-- }
--------------------------------------------------------------------

set :: (IQName, Int) -> CStmt
set (name,arity) 
 = do comment $ uninstance name
      let args = (("field", "root") : makeArgs [1..arity] ++ [("int", "missing")])
      hfunDefn "void" args ("set_"++mangle name) 
         do stmt $ symbol "root" .= (symptr name)
            stmt $ missing "root" .= "missing"
            stmt $ makeArray True arity
            mapM_ stmt $ [children "root" [x] .= var y)  
                              | (x,y) <- zip [0..] (reverse [1 .. arity])]
            mapM_ stmt $ [children "root" [x] ++ ".n" .= "NULL" | x <- [arity..2]] 
      nl

setType :: IDataType -> CStmt
setType (IDataType _ cons) = mapM_ set cons

setFun :: IFunction -> CStmt
setFun (IFunction name arity _ _ _) = set (name,arity)

--------------------------------------------------------------------
-- make_f functions
-- These allocate memory for a new node holding either a function
-- or a constructor
-- q.f :: Int -> Int -> Int
-- will have a make_q_f function that looks like
-- field make_q_f(int missing, field v1, field v2)
-- {
--     field root;
--     root.n = alloc(3);
--     root.n->symbol = &q_f_symbol;
--     root.missing = missing;
--     child_at_i(root,0) = v2;
--     child_at_i(root,1) = v1;
--     child_at_i(root,2) = NULL;
--     return root;
-- }
--------------------------------------------------------------------

make :: (IQName, Int) -> Stmt
make (name,arity) 
 = do comment $ uninstance name
      let args = makeArgs [1..arity] ++ [("int", "missing")]
      hfunDefn "field" ("make_"++mangle name) args 
        do stmt "field root"
           stmt "root.n" .= alloc_n 1
           symbol "root" .= (symptr name)
           stmt missing "root" .= "missing"
           makeArray False arity
           mapM_ stmt $ [children "root" [x] .= var y ++ ";") |
                           (x,y) <- zip [0..] (reverse [1..arity]]
           creturnExp "root"
      nl

-- Constants are different because we only ever make one of them,
-- so the make function just returns the one that's already made.
-- field make_Prelude_Nothing(int missing)
-- {
--     return Prelude_Nothing;
-- }
makeConstant :: IQName -> CStmt
makeConstant name 
  = do comment $ uninstance name
       hfunDefn "field" (mangle name) [("int", "missing")]
           do creturnExp (mangle name)
       nl

makeType :: IDataType -> CStmt
makeType (IDataType _ cons) 
  = do mapM_ make         [(n,a) | (n,a) <- cons, a > 0]
       mapM_ makeConstatn [n | (n,0) <- cons]

makeFun :: IFunction -> CStmt
makeFun (IFunction name arity _ _ _) = make (name,arity)

-----------------------------------------------------------------------
-- functions for making and seting free variables
-----------------------------------------------------------------------

setTypeFree :: IDataType -> CStmt
setTypeFree (IDataType _ cons) = mapM_ setConFree cons

setConFree :: (IQName, IArity) -> CStmt
setConFree (n, a) 
 = do comment $ uninstance n
      hfunDefn "void" (mangle n) [("field", "root")] body
        do stmt $ symbol "root" .= (symptr n)
           stmt $ nondet "root" .= "true"
           stmt $ missing "root" .= "0"
           makeArray True a
           mapM_ stmt $ [children "root" [x] .= var y ++ ";") |
                           (x,y) <- zip [0..] (reverse [1..a])]
      nl

makeTypeFree :: IDataType -> CStmt
makeTypeFree (IDataType _ cons) = mapM_ makeConFree cons

makeConFree :: (IQName, IArity) -> CStmt
makeConFree (n, a) 
 = do hfunDefn "field" (mangle name) []
        do stmt "field root"
           stmt $ "root.n" .= alloc_n 1
           stmt $ nondet "root" .= "true"
           stmt $ symbol "root" .= (symptr name)
           stmt $ missing "root" .= "0"
           makeArray False a
           mapM_ stmt $ [children "root" [x] .= "free_var();" | x <- [0..a-1]]
           returnExp "root"
      nl

------------------------------------------------------------------------
-- helper functions
------------------------------------------------------------------------


-- get q_f_symbol for function f
sym :: IQName -> String
sym n = mangle n ++ "_symbol"

-- get &q_f_symbol for function f
symptr :: IQName -> String
symptr n = "&" ++ (sym n)

-- turn a list of args into (field v1, field v2, ...)
makeArgs :: [Int] -> [(String, String)]
makeArgs = map (\v -> ("field", var v))

-- because I use calloc for memory allocation,
-- I don't need to actually NULL out the array pointer
-- for the node that are newly allocated.
-- so anything coming from make_f is fine.
--
-- I DO need to NULL out the array pointer for any set_f function,
-- since it might have been used before and have a non-NULL array pointer.
makeArray :: Bool -> Int -> CStmt
makeArray nullable arity
 | arity > 3 = stmt $ "root.n->children[3].a" .= alloc_f (arity - 3)
 | nullable  = stmt $ "root.n->children[3].a" .= "NULL"
 | otherwise = return ()