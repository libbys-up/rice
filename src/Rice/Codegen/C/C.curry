------------------------------------------------------------------------------
--- A small DSL for emitting C source, built on `Text.Pretty`'s `Doc` --
--- see `src/codegen-runtime-review.md`'s case for this over old_rice's
--- `String`-typed version: correct indentation/line-breaking falls out of
--- `Doc` structurally (via `nest`/`$$`), instead of every helper having to
--- hand-thread a `tab` depth and get it right. Modeled on the same idiom
--- the external `icurry` package's own `ICurry.Pretty` already uses for a
--- structurally similar job (blocks, statements, expressions) -- `nest`
--- for indentation, `$$` to stack lines, `<+>`/`<>` for same-line
--- concatenation.
---
--- `CStmt`/`CExpr` are both just `Doc`: a `CStmt` is one complete,
--- semicolon-or-brace-terminated statement (possibly itself a multi-line
--- block), and a sequence of statements is `vcat` of them, not a separate
--- list type -- there's no `[CStmt]` vs `CStmt` distinction to keep
--- straight the way old_rice's list-of-lines version needed.
---
--- Deliberately excluded (see `STATUS.md`'s Phase 1 scoping): every
--- RET/case-shortcutting-specific helper old_rice's `Compile.C` had
--- (`ret_hnf`, `backup`, `nbackup`, `make_restore`, `fwd`, `isRET`,
--- `hasRET`) -- that machinery is Phase 2 work, and porting the helpers
--- now with nothing to call them would just be unused code to maintain.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Codegen.C.C where

import Text.Pretty
import ICurry.Types (IQName, IVarIndex)
import Rice.Codegen.Names (mangle)

--- A C type, written out verbatim (`"int"`, `"field"`, `"Node*"`, ...).
type CType = String

--- A C identifier.
type CName = String

--- One complete C statement -- a single line (`x = y;`) or a whole nested
--- block (an `if`, a `switch`, a function definition); either way, one
--- `Doc` that renders as itself, no wrapping required to sequence it with
--- others (just `vcat`/`$$`).
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

--- A complete, semicolon-terminated assignment statement -- unlike
--- old_rice's `(.=)`, which returned a bare `CExpr` and left every call
--- site to remember its own trailing `;` (a real, repeated source of bugs
--- when ported verbatim -- see the review doc), this always finishes the
--- statement.
(.=) :: CExpr -> CExpr -> CStmt
x .= e = x <+> equals <+> e <> semi

(.|=) :: CExpr -> CExpr -> CStmt
x .|= e = x <+> text "|=" <+> e <> semi

------------------------------------------------------------------------------
-- Preprocessor
------------------------------------------------------------------------------

--- `file` is a module name, possibly hierarchical (e.g. `Test.Prop.Types`).
--- `Rice.Build.Cache`'s `moduleBase`/`modNameToPath` lays such a module's
--- `.c`/`.h` out in a directory tree matching its qualification
--- (`Test/Prop/Types.h`), named only by its *last* component
--- (`Types.h`, not `Test.Prop.Types.h`) -- `Rice.Main.buildExecutable`'s
--- `-I` flags (one per module's own directory) are what make plain
--- `"Types.h"` resolve correctly from anywhere it's included, so this
--- must include just that base name, not the full dotted one. Confirmed
--- by actually compiling a module with a hierarchical name (`Test.Prop`,
--- `Test.Prop.Types`): using the dotted name here verbatim compiled fine
--- for the many modules with plain (undotted) names every prior test
--- exercised, but failed as soon as one actually had a dot in it --
--- `clang: fatal error: 'Test.Prop.Types.h' file not found`, since no
--- file by that literal (dotted) name exists anywhere on the include
--- path.
cinclude :: CName -> CStmt
cinclude file = text "#include" <+> dquotes (text (baseModName file) <> text ".h")

--- The last component of a (possibly hierarchical) module name --
--- `"Test.Prop.Types"` -> `"Types"`. The identity on an already-unqualified
--- name (`"runtime"`, `"debug"`, ...), so this is safe to apply uniformly
--- regardless of which kind of name `cinclude` was actually given.
baseModName :: CName -> CName
baseModName = reverse . takeWhile (/= '.') . reverse

cdefine :: CName -> Int -> CStmt
cdefine name val = text "#define" <+> text name <+> int val

--- Wrap statements in `#if COND` / `#endif` -- e.g. gating a field access
--- behind the same build flag that determines whether the field exists at
--- all (`Rice.Codegen.C.ToH`'s epoch stamping, `OPT_EPOCH_TRAIL`). `cond`
--- is spliced in verbatim as a macro name, not an expression needing its
--- own escaping -- same trust level as `cdefine`'s own `name`. `CStmt`
--- being a plain `Doc` (this module's own header comment) is what makes
--- this possible with no DSL extension: a `#if`/`#endif` line is just
--- another `Doc` to stack via `$$`, not a construct needing its own type.
cifdef :: CName -> [CStmt] -> CStmt
cifdef cond body = (text "#if" <+> text cond) $$ vcat body $$ text "#endif"

------------------------------------------------------------------------------
-- Blocks and control flow
------------------------------------------------------------------------------

--- Indent width for a nested block -- matches `STYLE_GUIDE.md`'s C
--- convention (4-space indent, Allman braces: opening and closing braces
--- both at the enclosing statement's own indentation, only the body
--- nested).
blockIndent :: Int
blockIndent = 4

cblock :: [CStmt] -> CStmt
cblock body = lbrace $$ nest blockIndent (vcat body) $$ rbrace

cif :: CExpr -> [CStmt] -> CStmt
cif c body = text "if" <> parens c $$ cblock body

celse :: [CStmt] -> CStmt
celse body = text "else" $$ cblock body

cElseIf :: CExpr -> [CStmt] -> CStmt
cElseIf c body = text "else if" <> parens c $$ cblock body

cifElse :: CExpr -> [CStmt] -> [CStmt] -> CStmt
cifElse c t f = cif c t $$ celse f

--- An if/else-if/.../else chain -- one `CStmt` per condition, falling
--- through to a final, unconditional block.
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

comment :: String -> CStmt
comment s = text "//" <+> text s

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

--- A function meant to be force-inlined -- every `make_X`/`set_X` in the
--- generated header is one of these (matches `runtime.h`'s own
--- `__attribute__((always_inline)) static inline` convention for exactly
--- the same functions, hand-written there for the built-in constructors).
hfunDefn :: CType -> CName -> [(CType,CName)] -> [CStmt] -> CStmt
hfunDefn ret name ps body =
  text "__attribute__((always_inline))" $$
  text "static inline" <+> sig ret name ps $$
  cblock body

cfunDecl :: CType -> CName -> [(CType,CName)] -> CStmt
cfunDecl ret name ps = sig ret name ps <> semi

--- One entry of a designated-initializer list (`.field = value`, no
--- trailing `;` and no trailing `,` -- `carray`'s own `punctuate comma`
--- handles joining). Deliberately distinct from `(.=)`: that produces a
--- complete, semicolon-terminated *statement*; this produces one
--- comma-separated *entry* inside a `{ ... }` literal -- conflating the
--- two was a real bug risk in old_rice's version, which used the same
--- combinator for both and relied on every call site to manually append
--- or omit the right punctuation.
dinit :: String -> CExpr -> CExpr
dinit field val = text ('.':field) <+> equals <+> val

------------------------------------------------------------------------------
-- Argument/parameter lists, literals
------------------------------------------------------------------------------

cargs :: [CExpr] -> CExpr
cargs = parens . hsep . punctuate comma

--- An empty list prints as `(void)`: in C, `()` declares a function with
--- unspecified parameters, not none. (One rule with a `case`: two
--- overlapping rules would make `[]` print both ways, nondeterministically.)
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

--- Which `union field` member (`node.h`) a given `CType` lives in --
--- `"int"`/`"char"`/`"float"` are the type names used everywhere else in
--- this DSL (matching `litType`'s convention), but the union's own member
--- names are the single letters `.i`/`.c`/`.f`, not the full words.
fieldMember :: CType -> String
fieldMember t = case t of
  "int"   -> "i"
  "char"  -> "c"
  "float" -> "f"
  _       -> error ("Rice.Codegen.C.C.fieldMember: unknown type " ++ t)

--- Project a `field`-typed C expression down to one specific raw member
--- (`.i`/`.c`/`.f`) -- used both for a primitive operation's already-`field`
--- variable arguments (`showPrim` in `Rice.Codegen.C.PrimOps`) and for
--- comparing a literal-case scrutinee against a branch's literal value.
rawField :: CType -> CExpr -> CExpr
rawField t e = e <> dot <> text (fieldMember t)

--- The reverse: wrap a raw C value up as a `field`, via the GCC/clang
--- cast-to-union extension (`runtime.h`'s own `union field` and every
--- `__attribute__` in it already depend on GCC/clang, so this isn't a new
--- portability requirement). Used for a bare literal appearing directly
--- as an expression, not as a primitive operation's argument.
toUnion :: CType -> CExpr -> CExpr
toUnion t e = case t of
  "int"   -> text "(field)(long)"          <> parens e
  "char"  -> text "(field)(unsigned long)" <> parens e
  "float" -> text "(field)(double)"        <> parens e
  _       -> error ("Rice.Codegen.C.C.toUnion: unknown type " ++ t)

------------------------------------------------------------------------------
-- Children access
------------------------------------------------------------------------------

--- `child_at(n, i0)`, or `child_at(child_at(n, i0), i1)` for a nested
--- position -- `INodeAssign`'s `[Int]` position list is only ever more
--- than one element deep when assigning into an already-nested child, so
--- folding `child_at` is exactly the right traversal.
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

--- ICurry variable naming: `x0` is always the incoming node itself -- the
--- one index `ICurry.Types` itself documents as reserved (its own
--- `IVarDecl` note) -- so `v == 0` is the only special case here. Both
--- reference implementations this was designed against also hardcoded
--- `v == 1` to the name `"scrutinee"`, on the assumption a case's
--- scrutinee variable is always numbered 1; that's not actually reserved
--- by ICurry at all (confirmed empirically: an ordinary, unrelated
--- variable can just as easily be numbered 1), and the collision is a
--- real bug, not a hypothetical one -- `Rice.Codegen.C.ToC.showConsCase`'s
--- own internal scrutinee-copy variable (`scrutinee` below) is a genuinely
--- separate thing from whichever ICurry variable is being scrutinized,
--- and when that variable *happened* to be numbered 1, the naming
--- collision produced `field scrutinee = scrutinee;` -- self-referential
--- under C's scoping rules (the RHS names the just-declared local, not
--- any outer one), silently reading uninitialized memory. `varName` gives
--- the bare identifier (for parameter lists and declarations, which need a
--- plain `CName`, not an expression); `var` is the same name as a `CExpr`.
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

--- `root` names the incoming node (ICurry variable 0, see `varName`).
--- `scrutinee` is a name `Rice.Codegen.C.ToC.showConsCase` alone owns for
--- its own internal case-walking copy -- prefixed so it can never collide
--- with a real `"v" ++ show n` variable name (see `varName`'s note above).
--- `origScrutinee` is `showConsCase`'s own frozen snapshot of the
--- scrutinee's value *before* the dispatch loop below it ever runs --
--- distinct from `scrutinee` (which the loop reassigns as it chases
--- FUNCTION_TAG/CHOICE_TAG/FORWARD_TAG) and from `var v` (which
--- `showConsBranch`'s `writeBack` reassigns to the branch's own resolved
--- value, so by the time a branch body's SCOPED_RETRY would want "the
--- original", `var v` no longer holds it -- see `showConsCase`'s note).
root, scrutinee, origScrutinee :: CExpr
root          = text "root"
scrutinee     = text "_scrutinee"
origScrutinee = text "_orig"

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
--- `node.h`'s `Node.epoch` -- only actually a field under `OPT_EPOCH_TRAIL`
--- (see its own doc comment there); every generated reference to it is
--- correspondingly always wrapped in `cifdef "OPT_EPOCH_TRAIL"`, never used
--- bare.
epoch      v = v <> text ".n->epoch"

nullf :: CExpr
nullf = text "(field)(Node*)NULL"

--- The two debug-trace calls every function/case leaves with, matching
--- `archetecture.md`'s documented runtime convention (`debug`/`debug_expr`,
--- no-ops unless built with `-DDEBUG`).
debugLeave :: String -> [CStmt]
debugLeave msg =
  [ scall "debug"      [text "LOW", dquotes (text ("leaving " ++ msg ++ "\\n"))]
  , scall "debug_expr" [text "LOW", root]
  ]

------------------------------------------------------------------------------
