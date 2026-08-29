module Rice.CodeGen.C.ToC (writeMain, toC) where

import Data.Functional.DList
import Codegen.Names
import Codegen.CodeGen
import Codegen.CompileOpts

import ICurry.Types
import ICurry.Goodies

writeMain :: String -> CStmt
writeMain name
 = do 
     ainclude "stdio.h"
     mapM_ cinclude ["node", "stack", "runtime", "memory", name]
     stmt "Stack* bt_stack"
     stmt "unsigned long mem"
     nl
     nl
     cfunDefn "int" "main" []
       do stmt "bt_stack = new_stack()"
          nl
          scall "makeConstatns" []
          stmt "field root = make_"++(nameMangle name)++"_main(0);"
          scall "nf_all" ["root"]
          returnExp "0"

{-
 Flywheel pattern for constant values.  This is what actually needs the DataTable.
 where flywheel = 
      ["field Num[256];"] ++
      ["field "++mangle n++";" | n <- constants dt] ++
      nl ++
      ["void makeConstants()",
       "{"]++
      concat [["  "++mangle c++".n = (Node*)alloc(sizeof(Node));",
               "  "++mangle c++".n->symbol = &"++mangle c++"_symbol;",
               "  "++mangle c++".n->missing = 0;",
               "  "] | c <- constants dt] ++
      ["  for(int i = -127; i < 128; i++)",
      "  {",
      "      Num[i+127].n = (Node*)alloc(sizeof(Node));",
      "      Num[i+127].n->symbol = &int_symbol;",
      "      Num[i+127].n->missing = 0;",
      "      child_at_i(Num[i+127],0) = i;",
      "      child_at_i(Num[i+127],1) = INT_CTR;",
      "  }",
      "}",
-}



toC :: CompileOptions -> IProg -> String -> IO ()
toC opts ip file = writeCode file opts (toSource ip)

toSource :: IProg -> CStmt
toSource (IProg name imports data funcs) = 
 = do mapM_ include [name,"debug","runtime",imports]
      mapM_ toCFunc funcs

funSource :: IFunction -> CStmt
funSource (IFunction name _ _ _ body)
 | isExternal body = return ()
 | otherwise       = do comment (uninstance name)
                        cfunDefn "void" (hnf name) [("field", "root")]]
                           do funcBody False name body
                        nl

funcBody :: IQName -> IFuncBody -> CStmt
funcBody _ (IExternal x) = scall x ["root"]
funcBody n (IFuncBody block) 
  = do scall "debug" ["LOW", "\"HNF " ++ toName n ++ ":\\n\""]
       scall "debug_expr" ["LOW", "root"]
       emitBlock block

emitBlock :: String -> IBlock -> CStmt
emitBlock n (IBlock decls asgns stmt) 
  = do back <- backtrackOpt
       when back $ stmt $ "int stack_height" .= scall "height" ["bt_stack"]
       mapM_ emitDecl decls
       mapM_ emitAsgn asgns
       showStmt n stmt

emitStmt :: String -> IStatement -> CStmt
emitStmt n IExempt  = fail n
emitStmt (IReturn e) 
 = do setExpr pos e retFun
      scall "debug" ["LOW", "\"leaving " ++ n ++ "\\n\""],
      scall "debug_expr" ["LOW", "root"],
      creturn
emitStmt (ICaseCons v bs) 
 | v == -1   = showIfCase n pos bs (showBlock retFun)
 | otherwise = showConsCase n v bs
emitStmt (ICaseLit v bs) = showLitCase n v bs (showBlock retFun) retFun

fail :: Stirng -> CStmt
fail name = do scall "fail" ["root"]
               scall "debug" ["LOW", "\"leaving " ++ name ++ "\\n\""]
               scall "debug_expr" ["LOW", "root"]
               creturn

-- This is the main part of the code generator, so I should probably explain it
-- We'll use maybeNot as our example
-- maybeNot Nothing = False
-- maybeNot (Just b) = not b
-- in ICurry this is
-- maybeNot(root)
-- {
--    v = root[0]
--    case v
--      Nothing -> return False
--      Just b -> return not(b)
-- }
-- When we have a case expression, then we have * things to do
--  1. make a variable called scrutinee, and set it to v.
--     This is because v might be (or evaluate to) a forwarding node
--     In that case, we'll update scrutinee, and not change v (if its used later in the function)
--  2. keep trying to evaluate the scrutinee to head normal form.
--     Check the tag to see how to handle it.
--  3. the fail, fun, choice, forward, and free block are always the same.
--  4. for each branch generate the code for that branch.

emitConsCase :: String -> IVarIndex -> [IConsBranch] -> CStmt
emitConsCase v bs
  = cblock do stmt $ "field scrutinee" .= var v
              nondet <- nondetOpt
              when nondet $ stmt $ "bool nondet" .= "false"
              cwhile ctrue
                 do when nondet $ stmt $ "scrutinee" .|= nondet "scrutinee"
                    cswitch (tag "scrutinee")
                      ([ccase "FAIL_TAG"
                          do save v
                             back <- backtrackOpt
                             if back 
                                then do scall "backtrack" ["stack_height"]
                                        scall "debug" ["LOW", "\"backtracking @ stack_height\\n\""]
                                        cif (tag scrutinee .!= "FAIL_TAG") 
                                          do save v
                                             fail
                                else do save v
                                        fail
                        ,
                        ccase "FUNCTION_TAG"
                          do scall "HNF" ["scrutinee"]
                             cbreak
                        ,

                        funBlock v
                        choiceBlock v,
                        forwardBlock v,
                        freeBlock
                       ] ++ map showConsBranch v bs')
 where freeBlock = if isPrimitive bs
                    then 

showConsBranch :: IVarIndex -> IConsBranch -> CStmt
showConsBranch v (IConsBranch c _ b)
   = ccase (tag c)
       do save v
          emitBlock b

