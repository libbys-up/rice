------------------------------------------------------------------------------
--- Generates a module's C header (`Module.h`).
---
--- Every constructor and every function that isn't an inline primitive
--- gets a tag `#define`, a static `Symbol`, and the inline functions
--- `make_X` (allocate a node) and `set_X` (rewrite `root` in place).
--- Constructors also get `make_X_free` and `set_X_free`, which build the
--- constructor with free variables as its children, for narrowing.
---
--- Boxed `Int`, `Char` and `Float` are ordinary one-constructor types here;
--- the only thing special about them is the raw child their `reps` record.
--- Even a constructor with no children is allocated fresh by `make_X`; we
--- don't share preallocated copies.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Codegen.C.ToH (toHeader) where

import Data.Maybe (isJust)
import Text.Pretty

import ICurry.Types
import Rice.Codegen.C.C
import Rice.Codegen.C.PrimOps (lookupPrim)
import Rice.Codegen.Names (mangle, uninstance, toName, getTag)
import Rice.Codegen.FieldReps (FieldRep (..), FieldRepTable (..), isRaw)
import qualified Data.Map as Map

--- A module's whole header, as one `Doc` -- `pPrint` it and write the
--- result to `ModuleName.h`.
toHeader :: FieldRepTable -> IProg -> Doc
toHeader reps (IProg name imps types allFuns) = vcat $
  [ text ("#ifndef " ++ guardName ++ "_H")
  , text ("#define " ++ guardName ++ "_H")
  , text ""
  , cinclude "runtime"
  ] ++ map cinclude imps ++
  [ text "" ] ++
  map declareFun funs ++
  [ text "" ] ++
  concatMap makeTagsFor types ++
  concatMap (writeConSymbol reps) cons ++
  concatMap (writeFunSymbol reps) funs ++
  [ text "" ] ++
  concatMap setCon cons ++
  concatMap setFun funs ++
  concatMap makeCon cons ++
  concatMap makeFun funs ++
  concatMap (setConFree reps) cons ++
  concatMap (makeConFree reps) cons ++
  [ text ("#endif //" ++ guardName ++ "_H") ]
 where
  -- The whole module name, with `.` (not allowed in a macro name) as `_`.
  -- Just the last component wouldn't be unique: Foo.Types and Bar.Types.
  guardName = map (\c -> if c == '.' then '_' else c) name
  -- Primitives are inlined at every call site (Rice.Codegen.C.PrimOps),
  -- so they get nothing here.
  funs = [f | f@(IFunction n _ _ _ _) <- allFuns, not (isJust (lookupPrim n))]
  cons = [c | IDataType _ cs <- types, c <- cs]

------------------------------------------------------------------------------
-- Function prototypes, for the Symbols and for other modules' code
------------------------------------------------------------------------------

declareFun :: IFunction -> CStmt
declareFun (IFunction f _ _ _ _) = cfunDecl hnfRet (hnf f) hnfParams

------------------------------------------------------------------------------
-- Tags
------------------------------------------------------------------------------

makeTagsFor :: IDataType -> [CStmt]
makeTagsFor (IDataType _ cs) = map makeTag cs
 where makeTag (n,_) = cdefine (tag n) (getTag n + 5)

------------------------------------------------------------------------------
-- Symbols
------------------------------------------------------------------------------

symbolName :: IQName -> CName
symbolName n = mangle n ++ "_symbol"

repsName :: IQName -> CName
repsName n = mangle n ++ "_reps"

--- A symbol's definition, preceded by its `reps` array (`node.h`'s
--- `FieldRep`) when it has a raw slot. Without one, `.reps` is left out
--- and so is NULL: every child a pointer.
symbolLit :: IQName -> CExpr -> IArity -> [FieldRep] -> CExpr -> [CStmt]
symbolLit n tagExpr arity rs hnfExpr =
  [ (text "static const unsigned char" <+> text (repsName n) <> text "[]")
      .= carray (map repLit rs)
  | hasRaw ] ++
  [ (text "static Symbol" <+> text (symbolName n)) .=
      carray ([ dinit "tag"   tagExpr
              , dinit "arity" (int arity)
              , dinit "name"  (dquotes (text (toName n))) ] ++
              [ dinit "reps"  (text (repsName n)) | hasRaw ] ++
              [ dinit "hnf"   hnfExpr ])
  ]
 where
  hasRaw = any isRaw rs
  repLit r = text $ case r of
    RPtr   -> "R_PTR"
    RInt   -> "R_INT"
    RChar  -> "R_CHAR"
    RFloat -> "R_FLOAT"

--- The reps for a symbol, from the table; a name the table doesn't have
--- is all pointers.
lookupReps :: (FieldRepTable -> Map.Map (String, String) [FieldRep])
           -> FieldRepTable -> IQName -> [FieldRep]
lookupReps sel reps (m,n,_) = Map.findWithDefault [] (m,n) (sel reps)

writeConSymbol :: FieldRepTable -> (IQName, IArity) -> [CStmt]
writeConSymbol reps (n,a) =
  symbolLit n (text (tag n)) a (lookupReps frCons reps n) (text "&CTR_hnf")

writeFunSymbol :: FieldRepTable -> IFunction -> [CStmt]
writeFunSymbol reps (IFunction n a _ _ _) =
  symbolLit n (text "FUNCTION_TAG") a (lookupReps frFuns reps n)
            (text ('&' : hnf n))

------------------------------------------------------------------------------
-- set_X / make_X: shared child-array plumbing
------------------------------------------------------------------------------

makeArgs :: [Int] -> [(CType,CName)]
makeArgs = map (\v -> ("field", varName v))

--- Children 3 and up live in a spill array at `children[3].a` (`node.h`).
--- We always set that slot, to the array or to `NULL`, because `set_X`
--- may be rewriting a node that had a spill array before.
setChildArray :: IArity -> CStmt
setChildArray arity
  | arity > 3 = (root <> text ".n->children[3].a") .= alloc_f (arity - 3)
  | otherwise = (root <> text ".n->children[3].a") .= text "NULL"

--- Stores the arguments in `root`'s children in order: child 0 is the
--- first argument. ICurry's `IVarAccess` and `INodeAssign` index children
--- this way. (Apply nodes store theirs in reverse; that's in `runtime.h`.
--- See the developer's manual, "Argument order".)
setRealChildren :: IArity -> [CStmt]
setRealChildren arity = zipWith setChild [0 .. arity-1] [1 .. arity]
 where setChild i v = children root [i] .= var v

--- Clears child slots 0 to 2 that have no argument, since `root` may have
--- held something else before.
setUnusedChildren :: IArity -> [CStmt]
setUnusedChildren arity = map nullChild [arity .. 2]
 where nullChild i = (children root [i] <> text ".n") .= text "NULL"

--- Records the epoch a new node was created in (optimization #5). Only
--- `make_X` does this: `set_X` rewrites an existing node, whose age
--- doesn't change.
epochStamp :: CStmt
epochStamp = cifdef "OPT_EPOCH_TRAIL" [epoch root .= text "current_epoch"]

------------------------------------------------------------------------------
-- set_X
------------------------------------------------------------------------------

setEntry :: IQName -> IArity -> [CStmt]
setEntry name arity =
  [ comment (uninstance name)
  , hfunDefn "void" ("set_" ++ mangle name) args
      ( [ symbol root .= (text "&" <> text (symbolName name))
        , missing root .= text "missing"
        , setChildArray arity
        ] ++
        setRealChildren arity ++
        setUnusedChildren arity ++
        [ layoutCheck ("set_" ++ mangle name) ]
      )
  , text ""
  ]
 where args = ("field","root") : makeArgs [1..arity] ++ [("int","missing")]

setCon :: (IQName, IArity) -> [CStmt]
setCon (n,a) = setEntry n a

setFun :: IFunction -> [CStmt]
setFun (IFunction n a _ _ _) = setEntry n a

------------------------------------------------------------------------------
-- make_X
------------------------------------------------------------------------------

makeEntry :: IQName -> IArity -> [CStmt]
makeEntry name arity =
  [ comment (uninstance name)
  , hfunDefn "field" ("make_" ++ mangle name) args
      ( [ text "field root" <> semi
        , (root <> text ".n") .= alloc_n 1
        , epochStamp
        , symbol root .= (text "&" <> text (symbolName name))
        , missing root .= text "missing"
        , setChildArray arity
        ] ++
        setRealChildren arity ++
        [ layoutCheck ("make_" ++ mangle name)
        , creturnExpr root ]
      )
  , text ""
  ]
 where args = makeArgs [1..arity] ++ [("int","missing")]

--- `check_layout` (runtime.c) on a node just built, in builds with
--- `CHECK_LAYOUT` on. A NULL child is allowed here: it's a recursive
--- `let`'s placeholder, filled in right after.
layoutCheck :: String -> CStmt
layoutCheck fn =
  cifdef "CHECK_LAYOUT"
    [ scall "check_layout" [root, text "true", dquotes (text fn)] ]

makeCon :: (IQName, IArity) -> [CStmt]
makeCon (n,a) = makeEntry n a

makeFun :: IFunction -> [CStmt]
makeFun (IFunction n a _ _ _) = makeEntry n a

------------------------------------------------------------------------------
-- set_X_free / make_X_free, for narrowing (constructors only)
------------------------------------------------------------------------------

setChildFree :: Int -> CStmt
setChildFree i = children root [i] .= call "free_var" []

--- A free variable can't stand in a raw slot, so narrowing to a
--- constructor with a raw field (a primitive box) stops with an error
--- instead (`narrow_raw_error`, runtime.c).
narrowRawError :: IQName -> CStmt
narrowRawError n = scall "narrow_raw_error" [text "&" <> text (symbolName n)]

hasRawField :: FieldRepTable -> IQName -> Bool
hasRawField reps n = any isRaw (lookupReps frCons reps n)

setConFree :: FieldRepTable -> (IQName, IArity) -> [CStmt]
setConFree reps (n,a)
 | hasRawField reps n =
  [ hfunDefn "void" ("set_" ++ mangle n ++ "_free") [("field","root")]
      [ text "(void)root" <> semi, narrowRawError n ]
  , text ""
  ]
 | otherwise =
  [ hfunDefn "void" ("set_" ++ mangle n ++ "_free") [("field","root")]
      ( [ symbol root .= (text "&" <> text (symbolName n))
        , nondet root .= ctrue
        , missing root .= int 0
        , setChildArray a
        ] ++
        map setChildFree [0..a-1]
      )
  , text ""
  ]

makeConFree :: FieldRepTable -> (IQName, IArity) -> [CStmt]
makeConFree reps (n,a)
 | hasRawField reps n =
  [ hfunDefn "field" ("make_" ++ mangle n ++ "_free") []
      [ narrowRawError n
      , text "field root = {0}" <> semi
      , creturnExpr root ]
  , text ""
  ]
 | otherwise =
  [ hfunDefn "field" ("make_" ++ mangle n ++ "_free") []
      ( [ text "field root" <> semi
        , (root <> text ".n") .= alloc_n 1
        , epochStamp
        , nondet root .= ctrue
        , symbol root .= (text "&" <> text (symbolName n))
        , missing root .= int 0
        , setChildArray a
        ] ++
        map setChildFree [0..a-1] ++
        [ creturnExpr root ]
      )
  , text ""
  ]

------------------------------------------------------------------------------
