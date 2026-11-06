------------------------------------------------------------------------------
--- A small DSL for writing C source, built on `Text.Pretty`'s `Doc`, the
--- same way `ICurry.Pretty` prints ICurry: `nest` indents, `$$` stacks
--- lines, and `<+>`/`<>` join them.
---
--- `CStmt` and `CExpr` are both `Doc`. A `CStmt` is one complete statement,
--- ending in `;` or `}`, possibly over several lines; a sequence of
--- statements is just their `vcat`.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Codegen.C.C where

import Text.Pretty
import ICurry.Types (IQName, IVarIndex)
import Rice.Codegen.Names (mangle, escape)

--- A C type, written out verbatim (`"int"`, `"field"`, `"Node*"`, ...).
type CType = String

--- A C identifier.
type CName = String

--- One complete C statement: a line (`x = y;`) or a whole block (an `if`,
--- a `switch`, a function definition).
type CStmt = Doc

--- A C expression.
type CExpr = Doc

------------------------------------------------------------------------------
-- Operators
------------------------------------------------------------------------------

infixl 8 .*, ./, .%
infixl 7 .+, .-
infix  6 .==, .!=, .<, .>, .<=, .>=
infixr 5 .&
infixr 4 .|
infixr 3 .&&
infixr 2 .||
infixl 1 .=, .|=

binop :: String -> CExpr -> CExpr -> CExpr
binop op x y = x <+> text op <+> y

(.*), (./), (.%), (.+), (.-) :: CExpr -> CExpr -> CExpr
x .* y = binop "*" x y
x ./ y = binop "/" x y
x .% y = binop "%" x y
x .+ y = binop "+" x y
x .- y = binop "-" x y

(.==), (.!=), (.<=), (.>=), (.<), (.>) :: CExpr -> CExpr -> CExpr
x .== y = binop "==" x y
x .!= y = binop "!=" x y
x .<= y = binop "<=" x y
x .>= y = binop ">=" x y
x .<  y = binop "<"  x y
x .>  y = binop ">"  x y

(.&&), (.||), (.&), (.|) :: CExpr -> CExpr -> CExpr
x .&& y = binop "&&" x y
x .|| y = binop "||" x y
x .&  y = binop "&"  x y
x .|  y = binop "|"  x y

--- An assignment statement, with its `;`.
(.=) :: CExpr -> CExpr -> CStmt
x .= e = x <+> equals <+> e <> semi

(.|=) :: CExpr -> CExpr -> CStmt
x .|= e = x <+> text "|=" <+> e <> semi

------------------------------------------------------------------------------
-- Preprocessor
------------------------------------------------------------------------------

--- Includes a module's header. A hierarchical module `Test.Prop.Types`
--- has its header at `Test/Prop/Types.h` under its `.curry/rice-<version>/`
--- directory (`Rice.Build.Cache`), and `Rice.Main` passes that directory
--- with `-I`, so we include `"Test/Prop/Types.h"`. Including just
--- `"Types.h"` would be ambiguous: `Control.Monad.Trans.Class` and
--- `Control.Monad.IO.Class` would both be `"Class.h"`.
cinclude :: CName -> CStmt
cinclude file = text "#include" <+> dquotes (text (modPath file) <> text ".h")

--- A module name as a relative path: `"Test.Prop.Types"` ->
--- `"Test/Prop/Types"`.
modPath :: CName -> CName
modPath = map (\c -> if c == '.' then '/' else c)

cdefine :: CName -> Int -> CStmt
cdefine name val = text "#define" <+> text name <+> int val

--- Wraps statements in `#if cond` ... `#endif`, for code that only exists
--- under a build flag, like `OPT_EPOCH_TRAIL`'s epoch field.
cifdef :: CName -> [CStmt] -> CStmt
cifdef cond body = (text "#if" <+> text cond) $$ vcat body $$ text "#endif"

------------------------------------------------------------------------------
-- Blocks and control flow
------------------------------------------------------------------------------

--- The indentation of a block's body. Blocks use Allman braces, the same
--- as the hand-written runtime (`docs/style-guide.md`).
blockIndent :: Int
blockIndent = 4

cblock :: [CStmt] -> CStmt
cblock body = case body of
  [] -> lbrace $$ rbrace
  -- The line break has to be inside the `nest`, or the first statement
  -- isn't indented.
  _  -> lbrace <> nest blockIndent (linebreak <> vcat body) $$ rbrace

cif :: CExpr -> [CStmt] -> CStmt
cif c body = text "if" <> parens c $$ cblock body

celse :: [CStmt] -> CStmt
celse body = text "else" $$ cblock body

cElseIf :: CExpr -> [CStmt] -> CStmt
cElseIf c body = text "else if" <> parens c $$ cblock body

cifElse :: CExpr -> [CStmt] -> [CStmt] -> CStmt
cifElse c t f = cif c t $$ celse f

--- An if / else if / ... / else chain, ending in an unconditional block.
cifCase :: [(CExpr, [CStmt])] -> [CStmt] -> CStmt
cifCase []            fallback = cblock fallback
cifCase ((c,b):rest) fallback =
  cif c b $$ vcat (map (uncurry cElseIf) rest) $$ celse fallback

cwhile :: CExpr -> [CStmt] -> CStmt
cwhile c body = text "while" <> parens c $$ cblock body

cswitch :: CExpr -> [CStmt] -> CStmt
cswitch e cases = text "switch" <> parens e $$ cblock cases

ccase :: CExpr -> [CStmt] -> CStmt
ccase lbl body = text "case" <+> lbl <> colon $$ cblock body

creturn :: CStmt
creturn = text "return" <> semi

creturnExpr :: CExpr -> CStmt
creturnExpr e = text "return" <+> e <> semi

cbreak :: CStmt
cbreak = text "break" <> semi

ctrue, cfalse :: CExpr
ctrue  = text "true"
cfalse = text "false"

--- A C string literal holding `s`. Curry operator names can hold `\\` and
--- `"`, so every name that goes into a string literal goes through this.
cstring :: String -> CExpr
cstring s = dquotes (text (escape s))

--- A `//` comment. A comment ending in a backslash would continue onto
--- the next line of C, so one that does (the operator `\\`, say) is put
--- in backquotes.
comment :: String -> CStmt
comment s = text "//" <+> text s'
 where s' = if not (null s) && head (reverse s) == '\\' then "`" ++ s ++ "`" else s

------------------------------------------------------------------------------
-- Calls, functions
------------------------------------------------------------------------------

call :: CName -> [CExpr] -> CExpr
call name es = text name <> cargs es

scall :: CName -> [CExpr] -> CStmt
scall name es = call name es <> semi

retCall :: CName -> [CExpr] -> CStmt
retCall name es = text "return" <+> call name es <> semi

alloc_n :: Int -> CExpr
alloc_n n = case n of
  1 -> text "(Node*)alloc(sizeof(Node))"
  _ -> text "(Node*)alloc" <> parens (int n <+> text "* sizeof(Node)")

--- A node's spill array of `n` children (`runtime/memory.h`'s
--- `alloc_spill`, which adds the collector's header word).
alloc_f :: Int -> CExpr
alloc_f n = text "alloc_spill" <> parens (int n)

--- A C function's signature line, no trailing `;` or body.
sig :: CType -> CName -> [(CType,CName)] -> Doc
sig ret name ps = text ret <+> text name <> cparams ps

cfunDefn :: CType -> CName -> [(CType,CName)] -> [CStmt] -> CStmt
cfunDefn ret name ps body = sig ret name ps $$ cblock body

--- A function definition that's always inlined, like every `make_X` and
--- `set_X` in a generated header and in `runtime.h`.
hfunDefn :: CType -> CName -> [(CType,CName)] -> [CStmt] -> CStmt
hfunDefn ret name ps body =
  text "__attribute__((always_inline))" $$
  text "static inline" <+> sig ret name ps $$
  cblock body

cfunDecl :: CType -> CName -> [(CType,CName)] -> CStmt
cfunDecl ret name ps = sig ret name ps <> semi

--- One entry of a designated initializer, `.field = value`, with no
--- punctuation (`carray` adds the commas). Compare `(.=)`, a statement.
dinit :: String -> CExpr -> CExpr
dinit field val = text ('.':field) <+> equals <+> val

------------------------------------------------------------------------------
-- Argument/parameter lists, literals
------------------------------------------------------------------------------

cargs :: [CExpr] -> CExpr
cargs = parens . hsep . punctuate comma

--- An empty list prints as `(void)`: in C, `()` declares a function with
--- unspecified parameters, not none.
cparams :: [(CType,CName)] -> CExpr
cparams ps = case ps of
  [] -> text "(void)"
  _  -> parens (hsep (punctuate comma (map param ps)))
 where param (t,x) = text t <+> text x

carray :: [CExpr] -> CExpr
carray = braces . hsep . punctuate comma

------------------------------------------------------------------------------
-- Boxed-value payload access
------------------------------------------------------------------------------

--- The `union field` member (`node.h`) for a raw type: `"int"` is `i`,
--- `"char"` is `c`, `"float"` is `f`.
fieldMember :: CType -> String
fieldMember t = case t of
  "int"   -> "i"
  "char"  -> "c"
  "float" -> "f"
  _       -> error ("Rice.Codegen.C.C.fieldMember: unknown type " ++ t)

--- The raw value in a `field`: `e.i`, `e.c` or `e.f`.
rawField :: CType -> CExpr -> CExpr
rawField t e = e <> dot <> text (fieldMember t)

--- The reverse: a raw C value as a `field`, using the GCC/clang
--- cast-to-union extension. The runtime needs GCC or clang anyway.
toUnion :: CType -> CExpr -> CExpr
toUnion t e = case t of
  "int"   -> text "(field)(long)"          <> parens e
  "char"  -> text "(field)(unsigned long)" <> parens e
  "float" -> text "(field)(double)"        <> parens e
  _       -> error ("Rice.Codegen.C.C.toUnion: unknown type " ++ t)

------------------------------------------------------------------------------
-- Children access
------------------------------------------------------------------------------

--- The child of `n` at a path of child indices:
--- `child_at(child_at(n, i0), i1)` for `[i0, i1]`.
children :: CExpr -> [Int] -> CExpr
children n ixs = foldl childAt n ixs
 where childAt x i = call "child_at" [x, int i]

------------------------------------------------------------------------------
-- Curry-specific naming and node-field access
------------------------------------------------------------------------------

hnf :: IQName -> CName
hnf n = mangle n ++ "_hnf"

--- The return type of every `_hnf` function: machine code
--- (`runtime/machine.h`).
hnfRet :: CType
hnfRet = "RICE_CC void"

--- The parameters of every piece of machine code: the machine's two
--- registers, the node being reduced and the stack pointer.
hnfParams :: [(CType, CName)]
hnfParams = [("union field", "root"), ("Frame*", "sp")]

--- The same for a continuation, which finds its node in its frame
--- instead.
contParams :: [(CType, CName)]
contParams = [("union field", "_root"), ("Frame*", "sp")]

tag :: IQName -> CName
tag n = mangle n ++ "_TAG"

--- The C name of an ICurry variable. Variable 0 is the node being
--- reduced, `root`; every other variable `n` is `vn`. `varName` is the
--- identifier, and `var` is the same name as an expression.
varName :: IVarIndex -> CName
varName v
  | v == 0    = "root"
  | otherwise = "v" ++ show (abs v)

var :: IVarIndex -> CExpr
var = text . varName

--- Zero-initialized: a recursive `let` passes a variable to `make_X`
--- before a later `INodeAssign` fills in the node it names, so it must
--- read as NULL, not as whatever was on the stack.
fieldDecl :: IVarIndex -> CStmt
fieldDecl v = text "field" <+> var v <+> equals <+> text "{0}" <> semi

--- `root` is the node being reduced. `scrutinee` is the case loop's
--- working copy of the scrutinee (`Rice.Codegen.C.ToC`); its leading `_`
--- keeps it from clashing with a variable's `vn`.
root, scrutinee :: CExpr
root      = text "root"
scrutinee = text "_scrutinee"

symbol :: CExpr -> CExpr
symbol v = v <> text ".n->symbol"

symhnf :: CExpr -> CStmt
symhnf v = text "HNF" <> parens v <> semi

symtag, symname, symarity, nondet, missing, epoch :: CExpr -> CExpr
symtag     v = symbol v <> text "->tag"
symname    v = symbol v <> text "->name"
symarity   v = symbol v <> text "->arity"
nondet     v = v <> text ".n->nondet"
missing    v = v <> text ".n->missing"
--- `epoch` only exists under `OPT_EPOCH_TRAIL` (`node.h`), so it must
--- always be used inside `cifdef "OPT_EPOCH_TRAIL"`.
epoch      v = v <> text ".n->epoch"

nullf :: CExpr
nullf = text "(field)(Node*)NULL"

--- The trace every function and case prints when it leaves, under
--- `--debug` (`runtime/debug.h`).
debugLeave :: String -> [CStmt]
debugLeave msg =
  [ scall "debug"      [text "LOW", cstring "leaving %s\n", cstring msg]
  , scall "debug_expr" [text "LOW", root]
  ]

------------------------------------------------------------------------------
