------------------------------------------------------------------------------
--- Generates a module's C source (`Module.c`) from ICurry.
---
--- The generated code runs on the evaluation machine (`runtime/machine.h`):
--- each function is an `_hnf` function, and each constructor case in it is
--- a separate C function, a *case block*, whose frame on the machine stack
--- is its continuation. Control moves only by `musttail` jumps and
--- `RETURN()`, so the C stack doesn't grow. See the developer's manual,
--- "Generated code".
---
--- A literal case can't narrow a free variable: the scrutinee is a raw
--- value, and a free variable can't be one. We never get there, since
--- narrowing to a box with a raw child is an error (`narrow_raw_error`).
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

--- How the generated `main()` runs the root module's `main`.
---
--- `Standalone` (the default) runs `main :: IO t` once with `run_io`.
---
--- `Interactive` (`--interactive`) evaluates `main`, which can have any
--- type, with `nf_all`, and prints every solution. That's what a REPL
--- front end needs for a goal the user typed. Many of the test programs
--- are written this way too (`main :: [Int]`).
data MainMode = Standalone | Interactive
 deriving (Show, Eq)

mainDriverCall :: MainMode -> CStmt
mainDriverCall Standalone  = scall "run_io" [root]
mainDriverCall Interactive = scall "nf_all" [root]

--- The generated `rice-main.c`: defines the runtime's globals, initializes the
--- runtime, builds a node for the root module's `main`, and runs it with
--- the driver for `mode`. It also keeps the command line and rice's home,
--- `home`, for library externals (`runtime/ext.h`). The C compiler can
--- override `home` with `-DRICE_INSTALL_DIR=...`: a rice built from the
--- seed C (`tools/make-seed.sh`) is told where it was built, not where the
--- seed was generated.
writeMain :: String -> String -> MainMode -> Doc
writeMain rootModule home mode = vcat
  [ text "#include <stdio.h>"
  , cinclude "node"
  , cinclude "trail"
  , cinclude "runtime"
  , cinclude "memory"
  , cinclude rootModule
  , text ""
  , text "Trail* trail;"
  , text "unsigned long mem;"
  , text "int rice_argc;"
  , text "char** rice_argv;"
  , text "#ifndef RICE_INSTALL_DIR"
  , text "#define RICE_INSTALL_DIR" <+> cstring home
  , text "#endif"
  , text "const char* rice_install_dir = RICE_INSTALL_DIR;"
  , text ""
  , cfunDefn "int" "main" [("int","argc"), ("char**","argv")] $
      [ text "rice_argc = argc;"
      , text "rice_argv = argv;"
      , text "trail" <+> equals <+> call "trail_new" [] <> semi
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

--- What we know while generating one function. Its body up to the first
--- constructor case is `f_hnf`; each constructor case is a case block
--- `f_hnf_case<k>`.
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
  IExternal _     -> []  -- hand-written in runtime/ext/<module>.c
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

--- A function's entry code: a GC safe point, then its block.
---
--- `REWRITE_STAMP()` (runtime.h) records the epoch that nodes built for a
--- rewrite of `root` get under the write barrier. A rewrite outside any
--- constructor case is deterministic, so the stamp at entry is right.
--- Like every `OPT_*` macro, it expands to nothing when its flag is off;
--- the generated code is the same for every flag setting.
showBody :: Gen -> IBlock -> G [CStmt]
showBody gen block = do
  b <- showBlock gen block
  return $
    -- At entry every live pointer is in root, a frame, the trail or a C
    -- root, so the collector can run here.
    [ scall "GC_SAFE_POINT" [root, text "sp"]
    , scall "REWRITE_STAMP" []
    , scall "debug"      [text "LOW", cstring "HNF %s:\n", cstring (gLabel gen)]
    , scall "debug_expr" [text "LOW", root]
    ] ++ b

--- `Just v` inside a branch of a constructor case on `v`, and `Nothing`
--- outside any constructor case. A nested case replaces it, so it's
--- always the innermost case: the one a failure retries (`showStmt`).
type RetryCtx = Maybe IVarIndex

showBlock :: Gen -> IBlock -> G [CStmt]
showBlock gen (IBlock decls asgns stmt) = do
  st <- showStmt gen stmt
  return (map showDecl (dedupDecls decls) ++ map showAsgn asgns ++ st)

--- ICurry can declare the same variable twice in one block, which is a
--- redefinition in C. Keeps the first declaration of each variable.
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
showDecl (IFreeDecl v) = text "field" <+> var v <+> equals <+> stamped (call "free_var" []) <> semi

showAsgn :: IAssign -> CStmt
showAsgn (INodeAssign v ixs e) = children (var v) ixs .= showExpr e
showAsgn (IVarAssign  v e)     = var v .= showExpr e

--- A statement ends its block.
---
--- `IExempt` means no branch matched. Inside a constructor case we first
--- try scoped backtracking (#3, `SCOPED_RETRY` in runtime.h): if `undo`
--- flips a choice made since the case began, we dispatch again on the
--- case's original scrutinee. Otherwise we fail `root`. The failed retry
--- may have popped the trail entry the branch pushed for `root`, so
--- `SCOPED_RESAVE` trails `root` again before the `fail`.
showStmt :: Gen -> IStatement -> G [CStmt]
showStmt gen st = case st of
  IExempt ->
    return $
      maybe [] (const [ scall "SCOPED_RETRY" [scrutinee]
                      , scall "SCOPED_RESAVE" [root] ]) ctx ++
      uncaseTrail ctx ++
      scall "fail" [root] : debugLeave (gLabel gen) ++ leave gen returnStmt
  IReturn e ->
    let (body, term) = setExpr e
    in return (uncaseTrail ctx ++ body ++ debugLeave (gLabel gen) ++ leave gen term)
  ICaseCons v bs -> enterCase gen v bs
  ICaseLit  v bs -> showLitCase gen v bs
 where ctx = gRetry gen

--- Leaves the current code. Inside a case block we pop its frame first,
--- because we're leaving the case for good. `term` is the final transfer
--- of control: `RETURN()` or a jump.
leave :: Gen -> [CStmt] -> [CStmt]
leave gen term = maybe [] (const [text "sp" .= call "frame_pop" [text "sp"]]) (gRetry gen) ++ term

--- Return to the frame on top of the machine stack: `root` is in head
--- normal form.
returnStmt :: [CStmt]
returnStmt = [text "RETURN()" <> semi]

--- A tail call: reduce `root` with `code` (an expression of type `Code`),
--- which returns to wherever this code would have. `TAIL_CALL` (runtime.h)
--- jumps to `code` directly, or through `redispatch` with #2 off.
jumpTo :: CExpr -> [CStmt]
jumpTo code = [ call "TAIL_CALL" [code] <> semi ]

--- Trails a rewrite of `root` outside any constructor case. (Inside one,
--- the branch already called `trail_node`.) Nothing nondeterministic was
--- read, so with #1 on this is nothing; with #1 off, every rewrite has to
--- be trailed, this one included.
uncaseTrail :: RetryCtx -> [CStmt]
uncaseTrail Nothing  = [scall "trail_node" [root, cfalse]]
uncaseTrail (Just _) = []

------------------------------------------------------------------------------
-- Constructor cases
------------------------------------------------------------------------------

nondetVar :: CExpr
nondetVar = text "nondet"

--- Points the scrutinee variable at the node the loop ended on. A branch
--- reads the scrutinee's children through `v`, so `v` has to be the
--- constructor, not a FORWARD or a call that led to it. The graph itself
--- still points at the original node (see "FORWARD nodes" in the manual).
---
--- We never do this to `root` (variable 0): `root` is the node we were
--- asked to rewrite, and has to stay that node.
writeBack :: IVarIndex -> CStmt
writeBack v
  | v == 0    = comment "root is the scrutinee: no write-back"
  | otherwise = var v .= scrutinee

--- A constructor case: push its frame, filled from the variables in
--- scope here, and jump into its case block. The frame's slots are
---   0           root
---   1           the scrutinee variable, as it was when the case began
---   2           the dispatch loop's current scrutinee (`_scrutinee`)
---   3 ..        every other variable the branches use (`caseFreeVars`)
---   nondet      the loop's `nondet` flag (raw)
---   cutoff      the trail's height + 1 once the case may push a choice,
---               0 before (raw, #3; frame_push zeroes it, see
---               SCOPED_MARK_CUTOFF in runtime.h)
--- with reps from `gReps`, so the GC can trace it.
---
--- The loop's `nondet` starts at `root`'s own flag, not false: a node that
--- was rewritten nondeterministically stays that way. For a nested case,
--- this also brings in the enclosing case's flag, which its `trail_node`
--- put on `root`. (`backtracking_proofs.md`, nondet tracking rules 2, 3.)
---
--- The retry cutoff is per case, not per function: a retry only redoes
--- this case's dispatch, so it may only flip choices made since this case
--- began (`backtracking_proofs.md`, #3 rule 2).
enterCase :: Gen -> IVarIndex -> [IConsBranch] -> G [CStmt]
enterCase gen v bs = do
  (k, done) <- get
  put (k + 1, done)
  let fname = hnf (gName gen) ++ "_case" ++ show k
      frees = [ x | x <- caseFreeVars v bs, x /= 0, x /= v ]
      ndS   = 3 + length frees
      cutS  = ndS + 1
      repOf x = Map.findWithDefault RPtr x (gReps gen)
      -- the nondet flag, then the retry cutoff, which the collector
      -- adjusts when it compacts the trail (runtime/node.h, R_CUTOFF)
      slotReps = map repLit ([RPtr, RPtr, RPtr] ++ map repOf frees)
                 ++ ["R_INT", "R_CUTOFF"]
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
    [ rawSlot ndS .= nondet root
    , text "MUSTTAIL return" <+> text fname <> text "(root, sp)" <> semi ]

--- The prototype, reps array and `FrameInfo` of case block `k`.
--- `slotReps` are the reps' C names.
caseDecls :: Gen -> Int -> CName -> [String] -> [CStmt]
caseDecls gen k fname slotReps =
  [ text ("static " ++ hnfRet) <+> text fname <> cparams contParams <> semi
  , (text "static const unsigned char" <+> text (fname ++ "_reps[]"))
      .= carray (map text slotReps)
  , (text "static const FrameInfo" <+> text (fname ++ "_info"))
      .= carray [ dinit "code" (text fname)
                , dinit "size" (int (length slotReps))
                , dinit "reps" (text (fname ++ "_reps"))
                , dinit "name" (cstring (gLabel gen ++ " case " ++ show k)) ]
  ]

--- A field rep's C name.
repLit :: FieldRep -> String
repLit r = case r of
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
    [ text "field" <+> scrutinee <+> equals <+> slot 2 <> semi ] ++
    [ text "field" <+> var x <+> equals <+> slot (3 + i) <> semi
    | (i, x) <- zip [0 ..] frees ] ++
    [ text "bool" <+> nondetVar <+> equals <+> rawSlot ndS <> semi
    , scall "SCOPED_LOAD_CUTOFF" [int cutS]
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

--- The scrutinee failed, so `root` fails too, unless scoped backtracking
--- finds another choice to try first. With #3 on, the `fail` is always
--- trailed (`SCOPED_FAIL_TRAIL`, runtime.h), since the retry may have
--- popped entries the write depends on.
failBlock :: Gen -> CStmt
failBlock gen = ccase (text "FAIL_TAG")
  ( [ scall "SCOPED_RETRY" [scrutinee]
    , scall "SCOPED_FAIL_TRAIL" [nondetVar, root]
    , scall "fail" [root]
    ] ++ debugLeave (gLabel gen) ++ leave gen returnStmt
  )

--- The scrutinee still needs evaluating: save the loop's state in the
--- case's frame and jump to the scrutinee's code. When it reaches head
--- normal form it returns to this case block, which reloads and
--- re-dispatches.
funBlock :: Int -> CStmt
funBlock ndS = ccase (text "FUNCTION_TAG")
  [ scall "SCOPED_MARK_CUTOFF" []
  , slot 2 .= scrutinee
  , rawSlot ndS .= nondetVar
  , text "MUSTTAIL return" <+> scrutinee <> text ".n->symbol->hnf(" <> scrutinee <> text ", sp)" <> semi ]

choiceBlock :: CStmt
choiceBlock = ccase (text "CHOICE_TAG")
  [scall "SCOPED_MARK_CUTOFF" [], scall "choose" [scrutinee], cbreak]

--- `follow_forward` (runtime.h) moves one hop, or does path compression
--- under `OPT_PATH_COMPRESS`.
forwardBlock :: CStmt
forwardBlock = ccase (text "FORWARD_TAG")
  [ scrutinee .= call "follow_forward" [scrutinee], cbreak ]

--- Narrowing (see "Free variables and narrowing" in the manual): `x`
--- becomes the first constructor, and the trail gets a choice for each
--- other one and an entry that makes `x` free again at the end.
--- ICurry never has a case without branches, but we handle it anyway.
freeCaseBlock :: IVarIndex -> [IConsBranch] -> CStmt
freeCaseBlock _ []                                  =
  ccase (text "FREE_TAG")
    [scall "error" [dquotes (text "empty case has no constructors to narrow to"), root]]
freeCaseBlock v (IConsBranch first _ _ : restBs) =
  ccase (text "FREE_TAG") $
    [ scall "SCOPED_MARK_CUTOFF" []
    , scall "push_frame" [scrutinee, call "free_var" []] ] ++
    map pushChoice (reverse rest) ++
    [ scall ("set_" ++ mangle first ++ "_free") [scrutinee]
    , writeBack v
    , nondetVar .= ctrue
    , cbreak
    ]
 where
  rest = [c | IConsBranch c _ _ <- restBs]
  pushChoice c = scall "push_choice" [scrutinee, call ("make_" ++ mangle c ++ "_free") []]

--- A branch is a rewrite of `root`, trailed before its body runs. The
--- stamp for the nodes the body builds is read right after, from the
--- flag `trail_node` just set (see `REWRITE_STAMP`, runtime.h).
showConsBranch :: Gen -> IVarIndex -> IConsBranch -> G CStmt
showConsBranch gen v (IConsBranch c _ b) = do
  body <- showBlock gen b
  return (ccase (text (tag c))
                (writeBack v : scall "trail_node" [root, nondetVar] :
                 scall "REWRITE_STAMP" [] : body))

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

--- A literal case is an if/else chain on the raw value. It isn't a retry
--- point (`undo` can't restore a raw value), so its branches keep the
--- enclosing constructor case's `gRetry`.
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

--- A primitive's argument as a raw C value. After ANF it's always a
--- variable or a literal.
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
showExpr (IOr e1 e2)        = stamped (call "make_choice" [showExpr e1, showExpr e2])
showExpr (IFCall f es)
  | isApply f = stamped (call ("make_apply" ++ show (length es - 1)) (map showExpr es))
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
showComb f es = stamped (call ("make_" ++ mangle f) (map showExpr es ++ [int 0]))

showPart :: IQName -> Int -> [IExpr] -> CExpr
showPart f m es = stamped (call ("make_" ++ mangle f) (missingArgs es m))

--- A node built for `root`'s new value takes the rewrite's stamp under
--- the write barrier (`STAMPED`, runtime.h). A string constant's cells
--- don't need it: they're constructors, which are never rewritten.
stamped :: CExpr -> CExpr
stamped e = call "STAMPED" [e]

missingArgs :: [IExpr] -> Int -> [CExpr]
missingArgs es m = map showExpr es ++ replicate m nullf ++ [int m]

------------------------------------------------------------------------------
-- Expressions -- reducing root in place (IReturn)
------------------------------------------------------------------------------

--- Rewrites `root` with the value of a `return`. Returns the statements,
--- and how control leaves: `RETURN()` when `root` is already in head
--- normal form, or a tail jump to the code that reduces it further (a
--- function call, `?`, `apply`).
---
--- Returning an existing node (`IVar`, `IVarAccess`) is a collapsing rule:
--- `collapse` (runtime.h) makes `root` a FORWARD to it, or a copy under
--- `OPT_COPY_COLLAPSE` (#4).
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
