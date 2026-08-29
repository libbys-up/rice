--- Library for writing C code
--- This include several combinators for creating fragments of C code,
--- and is meant to help with the translation from ICurry to C.
---
--- This is a compromize between making a full IR to represent C
--- and just using strings for everything.
---
--- @author Michael Hanus
--- @version January 2013

module Codegen.C.C where

import ICurry.Types 
import Data.List (intercalate, isPrefixOf, splitOn, intersect)

import Codegen.CodeGen

-- Types of different pieces of C code
type CType = String
type CName = String
type CStmt = CodeGen ()
type CExpr = String
type CFunction = String

---- tab in a line of code
--tab :: Int -> String -> String
--tab n s
-- | n == 0    = s
-- | otherwise = "  " ++ tab (n-1) s

-------------------------------------------------------------------
-- Operators
-------------------------------------------------------------------

infixl 8 .*, ./
infixl 7 .+, .-
infix  6 .==, .!=, .<, .>, .<=, .>=
infixr 5 .&
infixr 4 .|
infixr 3 .&&
infixr 2 .||
infixl 1 .=, .|=


(.*) :: CExpr -> CExpr -> CExpr
x .* y = x ++ " * " ++ y

(./) :: CExpr -> CExpr -> CExpr
x ./ y = x ++ " / " ++ y

(.+) :: CExpr -> CExpr -> CExpr
x .+ y = x ++ " + " ++ y

(.-) :: CExpr -> CExpr -> CExpr
x .- y = x ++ " - " ++ y

(.==) :: CExpr -> CExpr -> CExpr
x .== y = x ++ " == " ++ y

(.!=) :: CExpr -> CExpr -> CExpr
x .!= y = x ++ " != " ++ y

(.<=) :: CExpr -> CExpr -> CExpr
x .<= y = x ++ " <= " ++ y

(.>=) :: CExpr -> CExpr -> CExpr
x .>= y = x ++ " >= " ++ y

(.<) :: CExpr -> CExpr -> CExpr
x .< y = x ++ " < " ++ y

(.>) :: CExpr -> CExpr -> CExpr
x .> y = x ++ " > " ++ y

(.&&) :: CExpr -> CExpr -> CExpr
x .&& y = x ++ " && " ++ y

(.||) :: CExpr -> CExpr -> CExpr
x .|| y = x ++ " || " ++ y

(.|=) :: CExpr -> CExpr -> CExpr
x .|= y = x ++ " |= " ++ y

(.|) :: CExpr -> CExpr -> CExpr
x .| y = x ++ " | " ++ y

(.&) :: CExpr -> CExpr -> CExpr
x .& y = x ++ " & " ++ y

(.=) :: CName -> CExpr -> CExpr
x .= e = x ++ " = " ++ e

-------------------------------------------------------------------------
-- Preprocessor
-------------------------------------------------------------------------

cinclude :: CName -> CStmt
cinclude file = emit $ "#include \"" ++ file ++ ".h\""

ainclude :: CName -> CStmt
ainclude file = emit $ "#include <" ++ file ++ ".h>"

cdefine :: CName -> Int -> CStmt
cdefine name val = emit $ "#define " ++ name ++ " " ++ show val

-------------------------------------------------------------------------
-- statements
-------------------------------------------------------------------------

comment :: String -> CStmt
comment str = emit $ "// " ++ str

big_comment :: [String] -> CStmt
big_comment strs = do emit "/*"
                      lift modify ((\t,c) -> (t+1,c))
                      mapM_ (emit . ("* "++)) strs
                      lift modify ((\t,c) -> (t-1,c))
                      emit " */"

stmt :: CStmt -> CStmt
stmt s = emit (s ++ ";")

call :: CName -> [CExpr] -> CExpr
call name es = name ++ cargs es

scall :: CName -> [CExpr] -> CStmt
scall name es = stmt (call name es)

alloc_n :: Int -> CExpr
alloc_n num
 | num == 1  = "(Node*)alloc(sizeof(Node))"
 | otherwise = "(Node*)alloc("++show num++" * sizeof(Node))"
alloc_f :: Int -> CExpr
alloc_f num
 | num == 1  = "(field*)alloc(sizeof(field))"
 | otherwise = "(field*)alloc("++show num++" * sizeof(field))"


creturn :: CStmt
creturn = emit "return;"

creturnExp :: CExp -> CStmt
creturnExp e = emit $ "return "++e++";"

retCall :: CName -> [CExpr] -> CStmt
retCall name es = creturnExp (call name es)

cbreak :: CStmt
cbreak = emit "break;"

ctrue :: CExp
ctrue = "true"

cfalse :: CExp
cfalse = "false"

cblock :: CStmt -> CStmt
cblock stmts = do emit "{"
                  modify (\(t,c) -> (t+2,c))
                  stmts
                  modify (\(t,c) -> (t-2,c))
                  emit "}"

cif :: CExpr -> CStmt -> CStmt
cif c b = do emit ("if(" ++ c ++ ")")
             cblock b


cifCase :: [(CExpr, CStmt)] -> CStmt -> CStmt
cifCase [] = return ()
cifCase ((c,b):bs) elseBlock 
  = do cif c b
       mapM_ celseIf bs
       celse elseBlock
 where celseIf (c,b) = do emit $ "else if("++c++")"
                          cblock b

cifElse :: CExpr -> CStmt -> CStmt -> CStmt
cifElse c t f = do cif c t
                   celse f

celse :: CStmt -> CStmt
celse b = do emit "else"
             cblock b

cwhile :: CExpr -> CStmt -> CStmt
cwhile c b = do emit $ "while(" ++ c ++ ")"
                cblock b

cswitch :: CExpr -> [CStmt] -> CStmt
cswitch e bs = do emit $ "switch("++ e ++ ")"
                  mapM_ cblock bs

ccase :: CExpr -> CStmt -> CStmt
ccase lbl body = do emit $ "case " ++ lbl ++ ":"
                    cblock body

-------------------------------------------------------------------------
-- functions
-------------------------------------------------------------------------

sig :: CType -> CName -> [(CType,CName)] -> String
sig ret name ps = ret ++ " " ++ name ++ cparams ps

-- function declarations are the same in both .c and .h files,
-- the definitions in .h file should always be inline.
funDecl :: CType -> CName -> [(CType,CName)] -> CStmt
funDecl ret name ps = emit $ sig ret name ps ++ ";"

cfunDefn :: CType -> CName -> [(CType,CName)] -> CStmt -> CStmt
cfunDefn ret name ps stmts = do emit $ sig ret name ps
                                cblock stmts

hfunDefn :: CType -> CName -> [(CType,CName)] -> CStmt -> CStmt
hfunDefn ret name ps stmts = do emit "__attribute__((always_inline)) "
                                emit $ "static inline " ++ sig ret name ps
                                cblock stmts

field :: IVarIndex -> CType
field v = "field " ++ (var v)

list :: [CExpr] -> CExpr
list = intercalate ", "

cargs :: [CExpr] -> CExpr
cargs xs = "(" ++ list xs ++ ")"

cparams :: [(CType,CExpr)] -> CExpr
cparams ps = "(" ++ list (map param ps) ++ ")"
 where param (t,x) = t ++ " " ++ x

carray :: [CExpr] -> CExpr
carray xs = "{" ++ list xs ++ "}"

---------------------------------------------------
-- RICE specific components
---------------------------------------------------

-- see archetecture.md for a description of the runtime data structures.
-- There is also child_at_v(node,index) for when the index is not a con

-- Get a child Node following a path.
children :: CName -> [Int] -> CExpr
children n xs = foldl childAt n xs
 where childAt x y = "child_at("++x++", "++show y++")"

-- get a child converted to the appropriate type
child_t :: CType -> CName -> CExpr
child_t "int" n   = "child_at_i("++n++",0)"
child_t "char" n  = "child_at_c("++n++",0)"
child_t "float" n = "child_at_f("++n++",0)"

-- converte any to to int/char/float
-- This is messy, but it will work anywhere.
conv_t :: CType -> CName -> CExpr
conv_t "int" n   = "((field)"++n++").i"
conv_t "char" n  = "((field)"++n++").c"
conv_t "float" n = "((field)"++n++").f"

-- convert anything to a field.
toUnion :: CType -> CExpr -> CExpr
toUnion "int" exp   = "(field)(long)("++exp++")"
toUnion "char" exp  = "(field)(unsigned long)("++exp++")"
toUnion "float" exp = "(field)(double)("++exp++")"

hnf :: IQName -> CName
hnf n = mangle n ++ "_hnf"

-- NOT USED IN THIS VERSION
-- keeping for later
-- ret_hnf :: IQName -> CName
-- ret_hnf n = mangle n ++ "_RET_hnf"

tag :: IQName -> String
tag f = mangle f ++ "_TAG"

-- variable index to a unique variable name
-- scrutinee is used for the case-shortcutting optimization
var :: Int -> CExpr
var v
 | v == 0    = "root"
 | v == 1    = "scrutinee"
 | otherwise = "v"++show (abs v)

node :: Int -> CExpr
node v = var v ++ ".n"

-- get the symbol for the node
symbol :: String -> CExpr
symbol v = v ++ ".n->symbol"

-- reduce variable v to head normal form.
symhnf :: CExpr -> CExpr
symhnf v = "HNF("++v++")"

symtag :: CExpr -> CExpr
symtag v = v ++ ".n->symbol->tag"

symname :: CExpr -> CExpr
symname v = v ++ ".n->symbol->name"

symarity :: CExpr -> CExpr
symarity v = v ++ ".n->symbol->arity"

root :: CExpr
root = "root"

------------------------------------------------------
-- Case-shortcutting specific
------------------------------------------------------
fwd :: Int -> CExpr
fwd v = var v ++ if v == 0 then "" else "_forward"

hasRET :: [IVarIndex] -> Bool
hasRET = not . null . isRET

isRET :: IVarIndex -> Bool
isRET v = v < (-1)

isScrutenee :: IVarIndex -> Bool
isScrutenee v = v == 1

nondet :: CExpr -> CExpr
nondet v = v ++ ".n->nondet"

missing :: CExpr -> CExpr
missing v = v ++ ".n->missing"

nullf :: CExpr
nullf = "(field)(Node*)NULL"

make_restore :: IVarIndex -> CStmt
make_restore v = nbackup v .= scall "make_restore" [nbackup v]

-- name of the backup node for case shortcutting node.
-- So if our variable is -5, then our backup name is backup5
backup :: IVarIndex -> CExpr
backup v
 | v < 0 = "backup"++show (abs v)
 | otherwise = var v

nbackup :: IVarIndex -> CExpr
nbackup v = backup v ++ ".n"

scrutinee :: CExpr
scrutinee = "scrutinee"

-------------------------------------
-- generating debugging code
-------------------------------------

debug_leave :: IQName -> CStmt
debug_leave n = do scall "debug" ["LOW", msg]
                   scall "debug_expr" ["LOW", root]
 where msg = "leaving " ++ toName n ++ "\\n"
