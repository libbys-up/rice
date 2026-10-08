------------------------------------------------------------------------------
--- ICurry -> C source (`ModuleName.c`) generation -- the core translation.
---
--- Generated code runs on the evaluation machine (`runtime/machine.h`,
--- `src/explicit-stack-plan.md`): every function body and every
--- constructor case (lifted into its own *case block*) is a
--- `RICE_CC void f(void)` that moves control only by `musttail` jumps and
--- `RETURN()`. A case evaluates its scrutinee by saving its state in its
--- frame and jumping to the scrutinee's code; tail calls are jumps. So
--- evaluation depth lives on Rice's own stack, not the C stack. An `_hnf`
--- function's contract is unchanged: when it returns, `root` is in head
--- normal form (or a forward/failure that the consumer resolves).
---
--- Deliberately excluded (matching `STATUS.md`'s Phase 1 scoping):
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

module Rice.Codegen.C.ToC (toSource, writeMain, MainMode (..)) where

import Data.Maybe (isJust)
import Data.Char (ord)
import Data.List (nub, (\\))
import qualified Data.Map as Map
import Control.Monad.Trans.State (State, get, put, runState)
import Text.Pretty

import ICurry.Types
import Rice.Codegen.C.C
import Rice.Codegen.C.PrimOps (PrimEntry, lookupPrim, primArgType, primMake, primSet)
import Rice.Codegen.Names (mangle, uninstance, toName, isStrConst, strConst)
import Rice.Codegen.FieldReps (FieldRep (..), FieldRepTable (..))

--- A module's whole `.c` file, as one `Doc`.
toSource :: FieldRepTable -> IProg -> Doc
toSource reps (IProg name imps _ allFuns) = vcat $
  [ cinclude name, cinclude "debug", cinclude "runtime" ] ++
  map cinclude imps ++
  [ text "" ] ++
  concatMap (funSource reps) codeFuns
 where
  -- Same filter as Rice.Codegen.C.ToH: primitives are inlined at every
  -- call site (below), never actually defined as a real function.
  codeFuns = [f | f@(IFunction n _ _ _ _) <- allFuns, not (isJust (lookupPrim n))]

isApply :: IQName -> Bool
isApply (m,n,_) = m == "Prelude" && n == "apply"

--- Which top-level driver generated `main()` should run the root module's
--- `main` through -- see `writeMain`, and `Rice.Main`'s `--interactive`
--- flag that produces this.
---
--- `Standalone` (the default) is what an ordinary compiled Curry program
--- wants: `main :: IO _`, run exactly once via `run_io` (runtime.c) --
--- no retry-on-backtracking loop, and no printing of a "result" (an IO
--- action's output is whatever side effects it already performed).
---
--- `Interactive` keeps this compiler's original, and still useful,
--- behavior: `nf_all` (runtime.c) evaluates the root `main` -- which
--- need not be `IO`-typed at all -- and prints *every* solution it can
--- backtrack its way into, exactly the "evaluate an arbitrary goal
--- expression, show every answer" behavior a REPL-style front end (e.g.
--- the `curry-repl` package's generated main-expression modules) needs
--- when it compiles a user's typed-in expression. Most of this
--- compiler's own `old_rice`-derived regression/benchmark corpus is
--- itself written in this older, bare-goal style (`main :: [Int]`, not
--- `IO ()`) rather than as real standalone programs, so `tests/run.sh`
--- passes this for those, not because it's the right default for
--- `rice` itself.
data MainMode = Standalone | Interactive
 deriving (Show, Eq)

mainDriverCall :: MainMode -> CStmt
mainDriverCall Standalone  = scall "run_io" [root]
mainDriverCall Interactive = scall "nf_all" [root]

--- The generated `main.c` for the root module: sets up the runtime's two
--- globals, evaluates the root module's `main` to normal form, and runs
--- it through whichever top-level driver `mode` selects (see `MainMode`).
--- No constant/flyweight preallocation (old_rice's/fast_backtrack's
--- `writeMain`'s `Num[256]`/`makeCrap`, needing a whole-program
--- `DataTable` this pass doesn't build) -- Phase 1 deliberately excludes
--- it, see `STATUS.md`.
writeMain :: String -> MainMode -> Doc
writeMain rootModule mode = vcat
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
      [ text "bt_stack" <+> equals <+> call "new_stack" [] <> semi
      , scall "memory_init" []
      , scall "machine_init" []
      , text "field root" <+> equals <+>
          call ("make_" ++ mangle (rootModule,"main",0)) [int 0] <> semi
      , mainDriverCall mode
      , creturnExpr (int 0)
      ]
  ]

------------------------------------------------------------------------------
-- Functions
------------------------------------------------------------------------------

--- A function's code runs on the evaluation machine (`runtime/machine.h`,
--- `src/explicit-stack-plan.md`). Its body up to the first constructor
--- case is `f_hnf` itself; every constructor case is lifted into its own
--- C function, a *case block* (`f_hnf_case<k>`), whose frame on the
--- machine stack is also its continuation: evaluating the scrutinee jumps
--- to the scrutinee's code, which returns by jumping back into the case
--- block. Control only ever moves by `musttail` jumps and `RETURN()`, so
--- the C stack doesn't grow with evaluation depth.
---
--- @field gName  the function, for naming its case blocks
--- @field gLabel its source name, for `--debug` messages
--- @field gReps  the field rep of each of its variables (`frVars`)
--- @field gRetry the innermost enclosing constructor case's scrutinee, if
---               any. Code is inside a case block's branch exactly when
---               this is `Just`, which is also exactly when that case's
---               frame is on top of the machine stack (see `leave`).
data Gen = Gen
  { gName  :: IQName
  , gLabel :: String
  , gReps  :: Map.Map Int FieldRep
  , gRetry :: RetryCtx
  }

--- One case block: the declarations that must precede any use of it
--- (prototype, reps array, `FrameInfo`), and its definition.
data CaseBlock = CaseBlock [CStmt] [CStmt]

--- Code generation for one function threads a case-block counter and the
--- case blocks generated so far.
type G a = State (Int, [CaseBlock]) a

funSource :: FieldRepTable -> IFunction -> [CStmt]
funSource reps (IFunction name _ _ _ body) = case body of
  IExternal _     -> []  -- hand-written in runtime/prelude.c
  IFuncBody block ->
    let (m, n, _) = name
        gen = Gen name (toName name)
                  (Map.findWithDefault Map.empty (m, n) (frVars reps)) Nothing
        (entry, (_, blocks)) = runState (showBody gen block) (0, [])
        cs = reverse blocks
    in [ comment (uninstance name) ] ++
       concat [ ds | CaseBlock ds _ <- cs ] ++
       [ cfunDefn hnfRet (hnf name) hnfParams entry
       , text "" ] ++
       concat [ d ++ [text ""] | CaseBlock _ d <- cs ]

--- backtracking-optimizations.md's #3: every function's trail-stack
--- cutoff is recorded once, here, before any of its own body could have
--- pushed anything -- SCOPED_CUTOFF() (runtime.h) is a no-op declaration
--- when OPT_SCOPED_BACKTRACK is off, so this line is always emitted,
--- identically, regardless of the flag: codegen never forks on an OPT_*
--- flag, only the macros' own expansion does.
showBody :: Gen -> IBlock -> G [CStmt]
showBody gen block = do
  b <- showBlock gen block
  return $
    [ scall "SCOPED_CUTOFF" []
    , scall "debug"      [text "LOW", dquotes (text ("HNF " ++ gLabel gen ++ ":\\n"))]
    , scall "debug_expr" [text "LOW", root]
    ] ++ b

--- `RetryCtx` is `Just v` while generating a case branch's own body (`v`
--- being *that* case's own scrutinee variable, from `showConsBranch`),
--- and `Nothing` everywhere else (top level, `Nothing`'s own default
--- case in a `case` block, etc.) -- `IExempt`'s own handling (`showStmt`)
--- uses it to retry the *innermost enclosing* case's scrutinee, if
--- there is one; a nested case's own branches get their own `Just`
--- (shadowing the outer one), so nesting resolves to "innermost wins"
--- for free, matching ordinary lexical scoping.
type RetryCtx = Maybe IVarIndex

showBlock :: Gen -> IBlock -> G [CStmt]
showBlock gen (IBlock decls asgns stmt) = do
  st <- showStmt gen stmt
  return (map showDecl (dedupDecls decls) ++ map showAsgn asgns ++ st)

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
--- A failed retry pops the `trail_node(root, nondet)` frame that
--- `showConsBranch` already pushed for this branch, so SCOPED_RESAVE
--- re-saves `root` before `fail` (see runtime.h) -- otherwise `fail(root)`
--- would be an unlogged write.
showStmt :: Gen -> IStatement -> G [CStmt]
showStmt gen st = case st of
  IExempt ->
    return $
      maybe [] (const [ scall "SCOPED_RETRY" [scrutinee, origScrutinee]
                      , scall "SCOPED_RESAVE" [nondetVar, root] ]) ctx ++
      uncaseTrail ctx ++
      scall "fail" [root] : debugLeave (gLabel gen) ++ leave gen returnStmt
  IReturn e ->
    let (body, term) = setExpr e
    in return (uncaseTrail ctx ++ body ++ debugLeave (gLabel gen) ++ leave gen term)
  ICaseCons v bs -> enterCase gen v bs
  ICaseLit  v bs -> showLitCase gen v bs
 where ctx = gRetry gen

--- Leaves the current code: pops the enclosing case block's frame first,
--- if there is one (`gRetry`), since control is leaving that case for
--- good -- every statement ends its block, so this is always a tail
--- position. `term` is the final transfer: `RETURN()` or a jump.
leave :: Gen -> [CStmt] -> [CStmt]
leave gen term = maybe [] (const [text "sp" .= call "frame_pop" [text "sp"]]) (gRetry gen) ++ term

--- Return to the frame on top of the machine stack: `root` is in head
--- normal form.
returnStmt :: [CStmt]
returnStmt = [text "RETURN()" <> semi]

--- A tail call: reduce `root` with `code` (an expression of type `Code`),
--- which returns to wherever this code would have.
jumpTo :: CExpr -> [CStmt]
jumpTo code = [ text "MUSTTAIL return" <+> code <> text "(root, sp)" <> semi ]

--- The trail point for a write to `root` that no constructor-case branch
--- covers (`Nothing`: a function body, or literal-case branch, with no
--- enclosing `showConsBranch`, whose own `trail_node` would otherwise have
--- run just before). Nothing nondeterministic was read on the way here,
--- so `nondet` is false: with OPT_NONDET_TRAIL on, `needs_trail` is
--- constant false and this compiles to nothing. With it off this is the
--- baseline trail every rewrite needs -- without it, #5 alone was unsound:
--- an old node rewritten here, untrailed, to point at a node younger than
--- the active choice point is exactly the #1+#5 failure (opt_conflict.md),
--- reproduced by counterexamples/StaleApply.curry, whose `o` is a let-
--- lifted function with no case. Emitted right before the write, after
--- any forcing, so the epoch check sees the choice points that forcing
--- created (setExpr itself never forces before writing `root`).
uncaseTrail :: RetryCtx -> [CStmt]
uncaseTrail Nothing  = [scall "trail_node" [root, cfalse]]
uncaseTrail (Just _) = []

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

--- A constructor case: push its frame, filled from the variables in
--- scope here, and jump into its case block. The frame's slots are
---   0           root
---   1           the scrutinee variable, as it was when the case began
---   2           the dispatch loop's current scrutinee (`_scrutinee`)
---   3 ..        every other variable the branches use (`caseFreeVars`)
---   nondet      the loop's `nondet` flag (raw)
---   cutoff      the function's SCOPED_CUTOFF (raw)
--- with reps from `gReps`, so the GC can trace it.
enterCase :: Gen -> IVarIndex -> [IConsBranch] -> G [CStmt]
enterCase gen v bs = do
  (k, done) <- get
  put (k + 1, done)
  let fname = hnf (gName gen) ++ "_case" ++ show k
      frees = [ x | x <- caseFreeVars v bs, x /= 0, x /= v ]
      ndS   = 3 + length frees
      cutS  = ndS + 1
      repOf x = Map.findWithDefault RPtr x (gReps gen)
      slotReps = [RPtr, RPtr, RPtr] ++ map repOf frees ++ [RInt, RInt]
      inner = gen { gRetry = Just v }
  body <- caseBody inner v frees ndS cutS bs
  (k', done') <- get
  put (k', CaseBlock (caseDecls gen k fname slotReps)
                     [cfunDefn ("static " ++ hnfRet) fname contParams
                               (text "(void)_root" <> semi : body)] : done')
  return $ leave gen $
    [ text "sp" .= call "frame_push" [text "sp", text ("&" ++ fname ++ "_info")]
    , slot 0 .= root
    , slot 1 .= var v
    , slot 2 .= var v ] ++
    [ slot (3 + i) .= var x | (i, x) <- zip [0 ..] frees ] ++
    [ rawSlot ndS .= int 0
    , scall "SCOPED_SAVE_CUTOFF" [slot cutS]
    , text "MUSTTAIL return" <+> text fname <> text "(root, sp)" <> semi ]

--- The prototype, reps array and `FrameInfo` of case block `k`.
caseDecls :: Gen -> Int -> CName -> [FieldRep] -> [CStmt]
caseDecls gen k fname slotReps =
  [ text ("static " ++ hnfRet) <+> text fname <> cparams contParams <> semi
  , (text "static const unsigned char" <+> text (fname ++ "_reps[]"))
      .= carray (map repLit slotReps)
  , (text "static const FrameInfo" <+> text (fname ++ "_info"))
      .= carray [ dinit "code" (text fname)
                , dinit "size" (int (length slotReps))
                , dinit "reps" (text (fname ++ "_reps"))
                , dinit "name" (dquotes (text (gLabel gen ++ " case " ++ show k))) ]
  ]
 where
  repLit r = text $ case r of
    RPtr   -> "R_PTR"
    RInt   -> "R_INT"
    RChar  -> "R_CHAR"
    RFloat -> "R_FLOAT"

--- A case block: reload the case's state from its frame, then run the
--- dispatch loop. It's entered both from `enterCase` and, after its
--- scrutinee is evaluated, by that evaluation's `RETURN()` -- either way
--- the frame holds everything, so the two are the same.
caseBody :: Gen -> IVarIndex -> [IVarIndex] -> Int -> Int -> [IConsBranch]
         -> G [CStmt]
caseBody gen v frees ndS cutS bs = do
  branches <- mapM (showConsBranch gen v) bs
  return $
    [ text "field" <+> root <+> equals <+> slot 0 <> semi ] ++
    [ text "field" <+> var v <+> equals <+> slot 1 <> semi | v /= 0 ] ++
    [ text "field" <+> scrutinee <+> equals <+> slot 2 <> semi
    , text "field" <+> origScrutinee <+> equals <+> slot 1 <> semi ] ++
    [ text "field" <+> var x <+> equals <+> slot (3 + i) <> semi
    | (i, x) <- zip [0 ..] frees ] ++
    [ text "bool" <+> nondetVar <+> equals <+> rawSlot ndS <> semi
    , scall "SCOPED_LOAD_CUTOFF" [slot cutS]
    , cwhile ctrue
        [ nondetVar .|= nondet scrutinee
        , cswitch (symtag scrutinee)
            ( [ failBlock gen, funBlock ndS, choiceBlock, forwardBlock
              , freeCaseBlock v bs ] ++
              branches )
        ]
    ]

slot :: Int -> CExpr
slot i = text ("SLOT(" ++ show i ++ ")")

rawSlot :: Int -> CExpr
rawSlot i = slot i <> text ".i"

--- The variables a case uses that it doesn't declare itself: its
--- scrutinee, plus everything its branches read from an enclosing scope.
--- ICurry variable numbers are unique within a function, so one set
--- difference over the whole subtree is enough.
caseFreeVars :: IVarIndex -> [IConsBranch] -> [IVarIndex]
caseFreeVars v bs =
  nub (v : concatMap (usedBlock . branchBlock) bs)
    \\ concatMap (declBlock . branchBlock) bs
 where branchBlock (IConsBranch _ _ b) = b

usedBlock :: IBlock -> [IVarIndex]
usedBlock (IBlock _ asgns st) = concatMap usedAsgn asgns ++ usedStmt st
 where
  usedAsgn a = case a of
    IVarAssign  _ e   -> usedExpr e
    INodeAssign x _ e -> x : usedExpr e
  usedStmt s = case s of
    IExempt         -> []
    IReturn e       -> usedExpr e
    ICaseCons x cbs -> x : concat [ usedBlock b | IConsBranch _ _ b <- cbs ]
    ICaseLit  x lbs -> x : concat [ usedBlock b | ILitBranch _ b <- lbs ]

usedExpr :: IExpr -> [IVarIndex]
usedExpr e = case e of
  IVar x           -> [x]
  IVarAccess x _   -> [x]
  ILit _           -> []
  IFCall _ es      -> concatMap usedExpr es
  ICCall _ es      -> concatMap usedExpr es
  IFPCall _ _ es   -> concatMap usedExpr es
  ICPCall _ _ es   -> concatMap usedExpr es
  IOr e1 e2        -> usedExpr e1 ++ usedExpr e2

declBlock :: IBlock -> [IVarIndex]
declBlock (IBlock decls asgns st) =
  map declIdx decls ++ [ x | IVarAssign x _ <- asgns ] ++ declStmt st
 where
  declIdx d = case d of
    IVarDecl  x -> x
    IFreeDecl x -> x
  declStmt s = case s of
    ICaseCons _ cbs -> concat [ declBlock b | IConsBranch _ _ b <- cbs ]
    ICaseLit  _ lbs -> concat [ declBlock b | ILitBranch _ b <- lbs ]
    _               -> []

--- `v` (this case's own scrutinee) is `_scrutinee` reaching FAIL_TAG
--- directly -- an upstream failure propagating through, as opposed to
--- `IExempt`'s "this scrutinee is fine, just unhandled". SCOPED_RETRY
--- goes first, before `root` is touched at all: `undo()` only walks the
--- trail stack, so it doesn't need `root` mutated first, and if it finds
--- nothing to flip, falling through to the unmodified trail_node/fail
--- sequence is exactly today's behavior either way.
failBlock :: Gen -> CStmt
failBlock gen = ccase (text "FAIL_TAG")
  ( [ scall "SCOPED_RETRY" [scrutinee, origScrutinee]
    , scall "trail_node" [root, nondetVar]
    , scall "fail" [root]
    ] ++ debugLeave (gLabel gen) ++ leave gen returnStmt
  )

--- The scrutinee still needs evaluating: save the loop's state in the
--- case's frame and jump to the scrutinee's code. When it reaches head
--- normal form it returns to this case block, which reloads and
--- re-dispatches.
funBlock :: Int -> CStmt
funBlock ndS = ccase (text "FUNCTION_TAG")
  [ slot 2 .= scrutinee
  , rawSlot ndS .= nondetVar
  , text "MUSTTAIL return" <+> scrutinee <> text ".n->symbol->hnf(" <> scrutinee <> text ", sp)" <> semi ]

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

showConsBranch :: Gen -> IVarIndex -> IConsBranch -> G CStmt
showConsBranch gen v (IConsBranch c _ b) = do
  body <- showBlock gen b
  return (ccase (text (tag c))
                (writeBack v : scall "trail_node" [root, nondetVar] : body))

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
showLitCase :: Gen -> IVarIndex -> [ILitBranch] -> G [CStmt]
showLitCase gen v bs = do
  conds <- mapM branchCond bs
  return [cifCase conds
            (uncaseTrail (gRetry gen) ++ scall "fail" [root] : leave gen returnStmt)]
 where
  branchCond (ILitBranch l b) = do
    body <- showBlock gen b
    return (rawField (litCType l) (var v) .== litValue l, body)

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

-- IVar/IVarAccess are "collapse points" (backtracking-optimizations.md's
-- #4): the function body's final value is just an already-existing node
-- reference, not a freshly-built one. `collapse` (runtime.h) is
-- set_forward under OPT_COPY_COLLAPSE=0 (the default), and only becomes an
-- eager, indirection-free copy when the flag is on *and* the referenced
-- node happens to already be a safe, non-nondet value at this point --
-- both branches are always sound, this is a runtime-flag-gated eager/lazy
-- trade, not a correctness fork here in codegen.
--
-- Returns the statements that rewrite `root`, and how control then leaves:
-- `RETURN()` when `root` is already in head normal form, or a tail jump to
-- the code that reduces it further (a function call, `?`, `apply`). The
-- jump is a `musttail` call, so a tail-recursive Curry function runs in
-- constant C stack.
setExpr :: IExpr -> ([CStmt], [CStmt])
setExpr (IVar v)           = ([scall "collapse" [root, var v]], returnStmt)
setExpr (IVarAccess v ixs) = ([scall "collapse" [root, children (var v) ixs]], returnStmt)
setExpr (ILit (IInt   i))  = ([(root <> text ".i") .= int i], returnStmt)
setExpr (ILit (IChar  c))  = ([(root <> text ".c") .= int (ord c)], returnStmt)
setExpr (ILit (IFloat f))  = ([(root <> text ".f") .= float f], returnStmt)
setExpr (IOr e1 e2)        =
  ([scall "set_choice" [root, showExpr e1, showExpr e2]], jumpTo (text "choice_hnf"))
setExpr (IFCall f es)
  | isApply f = ( [scall ("set_apply" ++ show (length es - 1)) (root : map showExpr es)]
                , jumpTo (text "apply_hnf") )
  | otherwise = case lookupPrim f of
      Just p  -> (primSet p root (map (showPrim (primArgType p)) es), returnStmt)
      Nothing -> ([setComb f es], jumpTo (text (mangle f ++ "_hnf")))
setExpr (ICCall c es)
  | isStrConst c = ([scall "setCurryString" [root, text (strConst c)]], returnStmt)
  | otherwise    = case lookupPrim c of
      Just p  -> (primSet p root (map (showPrim (primArgType p)) es), returnStmt)
      Nothing -> ([setComb c es], returnStmt)
setExpr (IFPCall f m es) = ([setPartComb f m es], returnStmt)
setExpr (ICPCall c m es) = ([setPartComb c m es], returnStmt)

setComb :: IQName -> [IExpr] -> CStmt
setComb f es = scall ("set_" ++ mangle f) (root : map showExpr es ++ [int 0])

setPartComb :: IQName -> Int -> [IExpr] -> CStmt
setPartComb f m es = scall ("set_" ++ mangle f) (root : missingArgs es m)

------------------------------------------------------------------------------
