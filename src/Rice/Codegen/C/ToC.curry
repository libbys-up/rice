------------------------------------------------------------------------------
--- ICurry -> C source (`ModuleName.c`) generation -- the core translation.
---
--- `setExpr`'s function-call/choice cases eagerly call
--- `F_hnf(root)`/`choice_hnf(root)`/`apply_hnf(root)` right after building
--- the node, matching both reference sources this was designed against
--- (old_rice's `Compile.ToC`, `~/curry/fast_backtrack`'s draft) -- this
--- was, briefly, mid-port, a deliberate *deviation* from both, reasoned as
--- "just an optimization, safe to defer to Phase 2's toggleable
--- backtracking-optimizations work." That reasoning was wrong, caught by
--- actually running the result (a real function's result printed as the
--- unevaluated call that built it, e.g. `main_LET0(True)`, not the value
--- `1`) rather than trusting the argument: an `_hnf` function's contract
--- is to leave `root` in actual weak head normal form when it returns --
--- `nf`'s own structure depends on that (`if(missing<=0) HNF(expr);` is
--- called *once*, not in a loop, then children are forced directly,
--- assuming `expr` itself is already stable). A `_hnf` that returns with
--- `root` as *another* pending `FUNCTION_TAG` call breaks that contract
--- silently -- `nf` never re-checks, so the caller sees the unevaluated
--- intermediate node. Reaching WHNF fully, not leaving it as "whatever
--- the next consumer's own dispatch loop happens to re-force," is baseline
--- correctness here, not an optional scheduling optimization on top of it.
--- The real, *documented* risk this eager form carries -- a self-recursive
--- tail call evaluates as `self_hnf` calling `self_hnf` directly, correct
--- only as far as the C compiler actually applies tail-call elimination --
--- is real and belongs on `backtracking-optimizations.md`'s list; wasn't
--- this port's to solve by silently leaving `_hnf` half-finished, but is
--- now solved properly, behind `OPT_TAIL_JUMP`: `tailDispatch` (below)
--- generates the *same* call either way, routed through `runtime.h`'s
--- `TAIL_DISPATCH` macro, so this file's own output doesn't fork on the
--- flag -- only which of "call it now" or "leave root pending, let
--- whatever consumes it next redispatch" the macro expands to does. `nf`
--- (and everything else that genuinely needs a settled value, not just
--- "whatever's next") was updated to `HNF_SETTLE`, a real trampoline
--- consumer, precisely so the assumption this comment describes
--- (`nf`'s single, non-looping `HNF(expr)`) keeps holding under the flag
--- instead of reopening the exact bug this paragraph is about.
---
--- Also deliberately excluded (matching `STATUS.md`'s Phase 1 scoping):
--- free-variable narrowing for a *literal* case's scrutinee. Ordinary
--- constructor cases (`ICaseCons`, always complete per `ICurry.Types`' own
--- contract) narrow a free scrutinee among their listed constructors as
--- normal. But by the time a value reaches an `ICaseLit` scrutinee, it's
--- been extracted directly out of a box's child slot (`IVarAccess`) --
--- which, for an *already-bound* box, is a raw scalar, but for a box that
--- was itself narrowed from a free variable via the generic
--- `make_X_free`/`set_X_free` machinery, would instead be a real
--- `FREE_TAG` node sharing the same `field` slot -- and nothing in this
--- codebase disambiguates those two representations safely (the closest
--- prior art, `runtime.c`'s `n.i < 1000001` check in `print_expr`, is a
--- fragile is-this-plausibly-a-heap-pointer heuristic, not something to
--- build real dispatch logic on without it being verified first). Rather
--- than guess at unverified pointer-safety logic, `ICaseLit` here assumes
--- its scrutinee is always already forced to a concrete literal -- true
--- for every case this session's test coverage exercises, false only for
--- a free variable of primitive type reaching a literal pattern match
--- (e.g. `let x free in x + 1`) -- and fails cleanly (falls through to the
--- same `fail(root)` an unmatched literal already produces) rather than
--- risking undefined behavior. A real fix needs the free/raw
--- disambiguation question resolved first; noted in `STATUS.md` as a
--- known Phase 1 gap, not silently absorbed.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Codegen.C.ToC (toSource, writeMain, StackSize (..)) where

import Data.Maybe (isJust)
import Data.Char (ord)
import Text.Pretty

import ICurry.Types
import Rice.Codegen.C.C
import Rice.Codegen.C.PrimOps (PrimEntry, lookupPrim, primArgType, primMake, primSet)
import Rice.Codegen.Names (mangle, uninstance, toName, isStrConst, strConst)

--- A module's whole `.c` file, as one `Doc`.
toSource :: IProg -> Doc
toSource (IProg name imps _ allFuns) = vcat $
  [ cinclude name, cinclude "debug", cinclude "runtime" ] ++
  map cinclude imps ++
  [ text "" ] ++
  concatMap funSource codeFuns
 where
  -- Same filter as Rice.Codegen.C.ToH: primitives are inlined at every
  -- call site (below), never actually defined as a real function.
  codeFuns = [f | f@(IFunction n _ _ _ _) <- allFuns, not (isJust (lookupPrim n))]

isApply :: IQName -> Bool
isApply (m,n,_) = m == "Prelude" && n == "apply"

--- What (if anything) generated `main()` should do about the process's
--- own stack `rlimit` before running anything else -- see `writeMain`,
--- and `Rice.Main`'s `--stack-size` flag that produces this. A stopgap
--- for genuine, non-tail recursion (`foldr` over a long list, etc.) that
--- `OPT_TAIL_JUMP`'s trampoline can't help with -- a real fix needs the
--- graph-reduction machine to stop using the C stack at all (planned
--- alongside an eventual LLVM backend); this just buys headroom within
--- whatever the OS's own hard limit allows in the meantime.
--- `StackSizeMax` requests exactly that hard limit -- runtime.c's
--- `set_stack_size_max` reads it at run time, since it varies by
--- machine and isn't known at compile time.
data StackSize = StackSizeMB Int | StackSizeMax
 deriving (Show, Eq)

stackSizeStmt :: Maybe StackSize -> [CStmt]
stackSizeStmt Nothing                = []
stackSizeStmt (Just StackSizeMax)    = [scall "set_stack_size_max" []]
stackSizeStmt (Just (StackSizeMB n)) = [scall "set_stack_size" [int (n * 1024 * 1024)]]

--- The generated `main.c` for the root module: sets up the runtime's two
--- globals, evaluates the root module's `main` to normal form, and prints
--- every solution found (`nf_all`, `runtime.c`). No constant/flyweight
--- preallocation (old_rice's/fast_backtrack's `writeMain`'s `Num[256]`/
--- `makeCrap`, needing a whole-program `DataTable` this pass doesn't
--- build) -- Phase 1 deliberately excludes it, see `STATUS.md`.
writeMain :: String -> Maybe StackSize -> Doc
writeMain rootModule stackSize = vcat
  [ text "#include <stdio.h>"
  , cinclude "node"
  , cinclude "stack"
  , cinclude "runtime"
  , cinclude "memory"
  , cinclude rootModule
  , text ""
  , text "Stack* bt_stack;"
  , text "unsigned long mem;"
  , text ""
  , cfunDefn "int" "main" [] $
      -- Deliberately the very first thing main() does, before any other
      -- setup: raising the stack rlimit only helps if it happens before
      -- anything (bt_stack/memory_init, then the program itself) has
      -- started using the stack.
      stackSizeStmt stackSize ++
      [ text "bt_stack" <+> equals <+> call "new_stack" [] <> semi
      , scall "memory_init" []
      , text "field root" <+> equals <+>
          call ("make_" ++ mangle (rootModule,"main",0)) [int 0] <> semi
      , scall "nf_all" [root]
      , creturnExpr (int 0)
      ]
  ]

------------------------------------------------------------------------------
-- Functions
------------------------------------------------------------------------------

funSource :: IFunction -> [CStmt]
funSource (IFunction name _ _ _ body) = case body of
  IExternal _     -> []  -- hand-written in external.c/Prelude_external.c
  IFuncBody block ->
    [ comment (uninstance name)
    , cfunDefn "void" (hnf name) [("field","root")] (showBody (toName name) block)
    , text ""
    ]

--- backtracking-optimizations.md's #3: every function's trail-stack
--- cutoff is recorded once, here, before any of its own body could have
--- pushed anything -- SCOPED_CUTOFF() (runtime.h) is a no-op declaration
--- when OPT_SCOPED_BACKTRACK is off, so this line is always emitted,
--- identically, regardless of the flag (matching TAIL_DISPATCH's own
--- convention: codegen never forks on an OPT_* flag, only the macros'
--- own expansion does).
showBody :: String -> IBlock -> [CStmt]
showBody n block =
  [ scall "SCOPED_CUTOFF" []
  , scall "debug"      [text "LOW", dquotes (text ("HNF " ++ n ++ ":\\n"))]
  , scall "debug_expr" [text "LOW", root]
  ] ++ showBlock Nothing n block

--- `RetryCtx` is `Just v` while generating a case branch's own body (`v`
--- being *that* case's own scrutinee variable, from `showConsBranch`),
--- and `Nothing` everywhere else (top level, `Nothing`'s own default
--- case in a `case` block, etc.) -- `IExempt`'s own handling (`showStmt`)
--- uses it to retry the *innermost enclosing* case's scrutinee, if
--- there is one; a nested case's own branches get their own `Just`
--- (shadowing the outer one), so nesting resolves to "innermost wins"
--- for free, matching ordinary lexical scoping.
type RetryCtx = Maybe IVarIndex

showBlock :: RetryCtx -> String -> IBlock -> [CStmt]
showBlock ctx n (IBlock decls asgns stmt) =
  map showDecl (dedupDecls decls) ++ map showAsgn asgns ++ showStmt ctx n stmt

--- The real ICurry the external `icurry` package generates can list the
--- same variable's `IVarDecl` more than once in one block (confirmed
--- empirically, e.g. Prelude's own `_def#===#...` methods) -- harmless at
--- the ICurry level (a second `declare x1` is redundant, not
--- contradictory), but `field x1;` twice in the same C scope is a hard
--- redefinition error. Keeps the first occurrence of each variable index.
dedupDecls :: [IVarDecl] -> [IVarDecl]
dedupDecls = dedupBy declIdx
 where declIdx (IVarDecl  v) = v
       declIdx (IFreeDecl v) = v

dedupBy :: (a -> Int) -> [a] -> [a]
dedupBy key = go []
 where go _    []     = []
       go seen (x:xs)
         | key x `elem` seen = go seen xs
         | otherwise         = x : go (key x : seen) xs

showDecl :: IVarDecl -> CStmt
showDecl (IVarDecl  v) = fieldDecl v
showDecl (IFreeDecl v) = text "field" <+> var v <+> equals <+> call "free_var" [] <> semi

showAsgn :: IAssign -> CStmt
showAsgn (INodeAssign v ixs e) = children (var v) ixs .= showExpr e
showAsgn (IVarAssign  v e)     = var v .= showExpr e

--- `IExempt` -- no branch matches -- is `Rice.Codegen.C.ToC`'s own header
--- comment's "incomplete pattern match", and per whoever's asking (the
--- session that added this) the main real-world way a program actually
--- fails. With an enclosing case's own scrutinee variable in scope
--- (`Just v`, from `showConsBranch`), try SCOPED_RETRY first: if
--- `undo(_cutoff)` finds and flips a choice point in this function's own
--- scope, resetting `_scrutinee` back to `v` and looping lets the SAME
--- case-dispatch loop (already present, already handling FORWARD_TAG the
--- same way) redispatch whatever undo restored, without ever touching
--- `root` at all. With no enclosing case (`Nothing` -- a function that's
--- unconditionally undefined), there's no local scrutinee to retry
--- against, so this falls straight through to the unmodified `fail`.
--- A failed retry pops the `save_copy(root)` that `showConsBranch` already
--- pushed for this branch, so SCOPED_RESAVE re-saves `root` before `fail`
--- (see runtime.h) -- otherwise `fail(root)` would be an unlogged write.
showStmt :: RetryCtx -> String -> IStatement -> [CStmt]
showStmt ctx n IExempt =
  maybe [] (const [ scall "SCOPED_RETRY" [scrutinee, origScrutinee]
                  , scall "SCOPED_RESAVE" [nondetVar, root] ]) ctx ++
  scall "fail" [root] : debugLeave n ++ [creturn]
showStmt _ n (IReturn e) =
  setExpr e ++ debugLeave n ++ [creturn]
showStmt _   n (ICaseCons v bs) = [showConsCase n v bs]
showStmt ctx n (ICaseLit  v bs) = [showLitCase ctx n v bs]

------------------------------------------------------------------------------
-- Constructor cases
------------------------------------------------------------------------------

nondetVar :: CExpr
nondetVar = text "nondet"

--- Write the loop's resolved value back into the *original* scrutinee
--- variable (`var v`) -- necessary because the ICurry block doesn't just
--- use the scrutinee for this one `case`; a matched branch's own body
--- (`IVarAccess v [...]`/`INodeAssign v [...]`) keeps referring to `var v`
--- directly, and needs to see the fully-resolved node (past any
--- FUNCTION_TAG/CHOICE_TAG/FORWARD_TAG the loop walked through), not the
--- original, possibly-still-pending one. Confirmed as a real bug, not a
--- hypothetical: a recursive function's result, read back this way
--- without the write-back, silently reinterpreted a `Node*` (the *original*
--- variable, left pointing at an intermediate FORWARD_TAG node) as a raw
--- `long` -- correct-looking control flow, silently wrong arithmetic.
---
--- Skipped when `v == 0`: that's `root` itself (`ICurry.Types`' own
--- reserved variable), and reassigning it here would be a *different*,
--- worse bug -- `root` is the specific `Node` the caller expects this
--- `_hnf` call to mutate in place; writing a resolved-but-different
--- pointer into the local `root` parameter would leave the caller's own
--- copy of it completely untouched, silently discarding this function's
--- entire result.
writeBack :: IVarIndex -> CStmt
writeBack v
  | v == 0    = comment "root scrutinized directly -- no write-back (see writeBack's own note)"
  | otherwise = var v .= scrutinee

showConsCase :: String -> IVarIndex -> [IConsBranch] -> CStmt
showConsCase n v bs = cblock
  [ text "bool" <+> nondetVar <+> equals <+> cfalse <> semi
  , text "field" <+> scrutinee <+> equals <+> var v <> semi
  , text "field" <+> origScrutinee <+> equals <+> var v <> semi
  , cwhile ctrue
      [ nondetVar .|= nondet scrutinee
      , cswitch (symtag scrutinee)
          ( [ failBlock n v, funBlock, choiceBlock, forwardBlock, freeCaseBlock v bs ] ++
            map (showConsBranch n v) bs
          )
      ]
  ]

--- `v` (this case's own scrutinee) is `_scrutinee` reaching FAIL_TAG
--- directly -- an upstream failure propagating through, as opposed to
--- `IExempt`'s "this scrutinee is fine, just unhandled". SCOPED_RETRY
--- goes first, before `root` is touched at all: `undo()` only walks the
--- trail stack, so it doesn't need `root` mutated first, and if it finds
--- nothing to flip, falling through to the unmodified save_copy/fail
--- sequence is exactly today's behavior either way.
failBlock :: String -> IVarIndex -> CStmt
failBlock n _ = ccase (text "FAIL_TAG")
  ( [ scall "SCOPED_RETRY" [scrutinee, origScrutinee]
    , cif nondetVar [scall "save_copy" [root]]
    , scall "fail" [root]
    ] ++ debugLeave n ++ [creturn]
  )

funBlock :: CStmt
funBlock = ccase (text "FUNCTION_TAG") [symhnf scrutinee, cbreak]

choiceBlock :: CStmt
choiceBlock = ccase (text "CHOICE_TAG") [scall "choose" [scrutinee], cbreak]

forwardBlock :: CStmt
forwardBlock = ccase (text "FORWARD_TAG")
  [ scrutinee .= children scrutinee [0], cbreak ]

--- `bs` is always non-empty (`ICaseCons`'s own well-formedness contract --
--- there's no value to scrutinize a zero-constructor type's variable at
--- all), but matched defensively rather than partially.
freeCaseBlock :: IVarIndex -> [IConsBranch] -> CStmt
freeCaseBlock _ []                                  =
  ccase (text "FREE_TAG")
    [scall "error" [dquotes (text "empty case has no constructors to narrow to"), root]]
freeCaseBlock v (IConsBranch first _ _ : restBs) =
  ccase (text "FREE_TAG") $
    [ scall "push_frame" [scrutinee, call "free_var" []] ] ++
    map pushChoice (reverse rest) ++
    [ scall ("set_" ++ mangle first ++ "_free") [scrutinee]
    , writeBack v
    , nondetVar .= ctrue
    , cbreak
    ]
 where
  rest = [c | IConsBranch c _ _ <- restBs]
  pushChoice c = scall "push_choice" [scrutinee, call ("make_" ++ mangle c ++ "_free") []]

showConsBranch :: String -> IVarIndex -> IConsBranch -> CStmt
showConsBranch n v (IConsBranch c _ b) =
  ccase (text (tag c))
    (writeBack v : cif nondetVar [scall "save_copy" [root]] : showBlock (Just v) n b)

------------------------------------------------------------------------------
-- Literal cases
------------------------------------------------------------------------------

litCType :: ILiteral -> CType
litCType (IInt   _) = "int"
litCType (IFloat _) = "float"
litCType (IChar  _) = "char"

litValue :: ILiteral -> CExpr
litValue (IInt   i) = int i
litValue (IFloat f) = float f
litValue (IChar  c) = int (ord c)

--- Takes the enclosing `RetryCtx` and threads it through *unchanged* --
--- a literal case doesn't establish its own SCOPED_RETRY-eligible
--- scrutinee (its own scrutinee is already an extracted raw scalar by
--- here, not a `field` `undo` can restore in place -- see runtime.h's
--- own note on SCOPED_RETRY), but an `IExempt` from a *further* nested
--- case inside one of these branches should still retry against
--- whichever constructor-case scrutinee most recently enclosed it, not
--- lose that context just because a literal case sits in between.
showLitCase :: RetryCtx -> String -> IVarIndex -> [ILitBranch] -> CStmt
showLitCase ctx n v bs = cifCase (map branchCond bs) (scall "fail" [root] : [creturn])
 where
  branchCond (ILitBranch l b) =
    (rawField (litCType l) (var v) .== litValue l, showBlock ctx n b)

------------------------------------------------------------------------------
-- Expressions -- building a new node
------------------------------------------------------------------------------

--- Project a primitive operation's already-bound argument down to its raw
--- value -- primitive arguments are always either a plain variable (a
--- `field` already holding the right raw member) or a literal constant;
--- anything else would mean `Rice.Transform.Unbox` produced something this
--- wasn't designed against.
showPrim :: CType -> IExpr -> CExpr
showPrim typ e = case e of
  IVar v -> rawField typ (var v)
  ILit l -> litValue l
  _      -> error ("Rice.Codegen.C.ToC.showPrim: primitive argument is neither a " ++
                    "variable nor a literal: " ++ show e)

showExpr :: IExpr -> CExpr
showExpr (IVar v)           = var v
showExpr (IVarAccess v ixs) = children (var v) ixs
showExpr (ILit l)           = toUnion (litCType l) (litValue l)
showExpr (IOr e1 e2)        = call "make_choice" [showExpr e1, showExpr e2]
showExpr (IFCall f es)
  | isApply f = call ("make_apply" ++ show (length es - 1)) (map showExpr es)
  | otherwise = primOrComb f es
showExpr (ICCall c es)
  | isStrConst c = call "toCurryString" [text (strConst c)]
  | otherwise    = primOrComb c es
showExpr (IFPCall f m es) = showPart f m es
showExpr (ICPCall c m es) = showPart c m es

primOrComb :: IQName -> [IExpr] -> CExpr
primOrComb f es = case lookupPrim f of
  Just p  -> primMake p (map (showPrim (primArgType p)) es)
  Nothing -> showComb f es

showComb :: IQName -> [IExpr] -> CExpr
showComb f es = call ("make_" ++ mangle f) (map showExpr es ++ [int 0])

showPart :: IQName -> Int -> [IExpr] -> CExpr
showPart f m es = call ("make_" ++ mangle f) (missingArgs es m)

missingArgs :: [IExpr] -> Int -> [CExpr]
missingArgs es m = map showExpr es ++ replicate m nullf ++ [int m]

------------------------------------------------------------------------------
-- Expressions -- reducing root in place (IReturn)
------------------------------------------------------------------------------

--- The eager `X_hnf(root)` call after building a function/choice/apply
--- node -- required for the `_hnf` contract (see this module's own header
--- comment: an `_hnf` function must leave `root` in actual WHNF, not
--- another unevaluated call). Constructors don't need this (`setComb`'s
--- `ICCall` case never calls it): a constructor application is already
--- its own WHNF once built -- `CTR_hnf` is a debug-only no-op precisely
--- because there's nothing left to reduce. Used for `choice` (below) only
--- -- `choice_hnf` is O(1) and never itself produces another pending
--- call, so there's nothing for backtracking-optimizations.md's #2 to
--- defer here; see `tailDispatch` for the two cases that do.
hnfCall :: CName -> CStmt
hnfCall name = scall (name ++ "_hnf") [root]

--- The tail-call/`apply` counterpart of `hnfCall`, for the two `setExpr`
--- cases that build a genuine tail call: a real `_hnf`/`apply_hnf`
--- dispatch every time, exactly like `hnfCall`, *unless*
--- `OPT_TAIL_JUMP` is on (`runtime.h`'s `TAIL_DISPATCH` macro), in which
--- case it's left for whatever consumes `root` next to notice it's still
--- FUNCTION_TAG and redispatch -- see `runtime.h`'s own doc comment on
--- `TAIL_DISPATCH` and backtracking-optimizations.md's #2. This is the
--- *only* difference from `hnfCall`: same generated code either way,
--- just routed through a macro instead of a direct call, so which
--- behavior actually happens is a link-time `-D` choice, not something
--- `rice` itself needs to be told about at codegen time.
tailDispatch :: CName -> CStmt
tailDispatch name = scall "TAIL_DISPATCH" [text (name ++ "_hnf"), root]

-- IVar/IVarAccess are "collapse points" (backtracking-optimizations.md's
-- #4): the function body's final value is just an already-existing node
-- reference, not a freshly-built one. `collapse` (runtime.h) is
-- set_forward under OPT_COPY_COLLAPSE=0 (the default), and only becomes an
-- eager, indirection-free copy when the flag is on *and* the referenced
-- node happens to already be a safe, non-nondet value at this point --
-- both branches are always sound, this is a runtime-flag-gated eager/lazy
-- trade, not a correctness fork here in codegen.
setExpr :: IExpr -> [CStmt]
setExpr (IVar v)           = [scall "collapse" [root, var v]]
setExpr (IVarAccess v ixs) = [scall "collapse" [root, children (var v) ixs]]
setExpr (ILit (IInt   i))  = [(root <> text ".i") .= int i]
setExpr (ILit (IChar  c))  = [(root <> text ".c") .= int (ord c)]
setExpr (ILit (IFloat f))  = [(root <> text ".f") .= float f]
setExpr (IOr e1 e2)        =
  [scall "set_choice" [root, showExpr e1, showExpr e2], hnfCall "choice"]
setExpr (IFCall f es)
  | isApply f = [ scall ("set_apply" ++ show (length es - 1)) (root : map showExpr es)
                , tailDispatch "apply"
                ]
  | otherwise = case lookupPrim f of
      Just p  -> primSet p root (map (showPrim (primArgType p)) es)
      Nothing -> [setComb f es, tailDispatch (mangle f)]
setExpr (ICCall c es)
  | isStrConst c = [scall "setCurryString" [root, text (strConst c)]]
  | otherwise    = case lookupPrim c of
      Just p  -> primSet p root (map (showPrim (primArgType p)) es)
      Nothing -> [setComb c es]
setExpr (IFPCall f m es) = [setPartComb f m es]
setExpr (ICPCall c m es) = [setPartComb c m es]

setComb :: IQName -> [IExpr] -> CStmt
setComb f es = scall ("set_" ++ mangle f) (root : map showExpr es ++ [int 0])

setPartComb :: IQName -> Int -> [IExpr] -> CStmt
setPartComb f m es = scall ("set_" ++ mangle f) (root : missingArgs es m)

------------------------------------------------------------------------------
