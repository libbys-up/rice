------------------------------------------------------------------------------
--- ICurry -> C header (`ModuleName.h`) generation.
---
--- Every constructor and non-primitive function gets: a tag `#define`, a
--- static `Symbol`, and `make_X`/`set_X` (`make_X_free`/`set_X_free` too,
--- for constructors). Two deliberate simplifications relative to both
--- reference sources this was designed against (see `STATUS.md`'s Phase 1
--- scoping and `src/codegen-runtime-review.md`):
---
--- - **No zero-arity-constructor/small-integer preallocation.** old_rice's
---   `writeMain` preallocated every 0-arity constructor and every `Int` in
---   [-127,128] as a flyweight, needing a whole-program `DataTable` this
---   pass doesn't have. Every constructor, 0-arity or not, just goes
---   through the same `make_X`/`set_X` as everything else -- correct,
---   marginally more allocation, no `DataTable` dependency.
--- - **Boxed `Int`/`Char`/`Float` need no special case at all**, beyond
---   setting `.payload` on their `Symbol` -- confirmed empirically (see
---   `archetecture.md`'s "Boxed primitives" section): by the time
---   `Rice.Transform.Unbox`'s output reaches real ICurry, a boxed value's
---   case branch is just an ordinary one-constructor `ICaseCons`, with no
---   dummy branches surviving to this stage. `Rice.Codegen.C.ToC` still
---   needed the empirical check; this file didn't need to know at all.
---
--- One bug found and fixed by actually running a compiled program, not
--- just reading the generated C: `setRealChildren` originally stored a
--- constructor/function's arguments into `root`'s child slots in
--- *reverse* order, copying old_rice's own convention uncritically. That
--- convention was old_rice's own ICurry generator's (`Compile.ToICurry`,
--- not what Rice actually uses) internal agreement with itself, not a
--- property of ICurry in general -- the external `icurry` package Rice
--- depends on indexes `IVarAccess`/`INodeAssign` in plain forward order,
--- and the mismatch was invisible in every arity-1 test (only one slot to
--- get "wrong") until a real arity-2 function (`(?)`, `True ? False`)
--- silently swapped its own two arguments. See `setRealChildren` below.
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

--- A module's whole header, as one `Doc` -- `pPrint` it and write the
--- result to `ModuleName.h`.
toHeader :: IProg -> Doc
toHeader (IProg name imps types allFuns) = vcat $
  [ text ("#ifndef " ++ name ++ "_H")
  , text ("#define " ++ name ++ "_H")
  , text ""
  , cinclude "runtime"
  ] ++ map cinclude imps ++
  [ text "" ] ++
  map declareFun funs ++
  [ text "" ] ++
  concatMap makeTagsFor types ++
  map writeConSymbol cons ++
  map writeFunSymbol funs ++
  [ text "" ] ++
  concatMap setCon cons ++
  concatMap setFun funs ++
  concatMap makeCon cons ++
  concatMap makeFun funs ++
  concatMap setConFree cons ++
  concatMap makeConFree cons ++
  [ text ("#endif //" ++ name ++ "_H") ]
 where
  -- Primitive functions (Rice.Codegen.C.PrimOps) are inlined at every call
  -- site (Rice.Codegen.C.ToC) and never actually invoked as real
  -- functions -- no declaration, no Symbol, no make/set for them at all.
  funs = [f | f@(IFunction n _ _ _ _) <- allFuns, not (isJust (lookupPrim n))]
  cons = [c | IDataType _ cs <- types, c <- cs]

------------------------------------------------------------------------------
-- Function prototypes (so `&F_hnf` in a Symbol literal, and any call to
-- F_hnf from another module's generated code, both have a declaration in
-- scope before they're used).
------------------------------------------------------------------------------

declareFun :: IFunction -> CStmt
declareFun (IFunction f _ _ _ _) = cfunDecl "void" (hnf f) [("field","root")]

------------------------------------------------------------------------------
-- Tags
------------------------------------------------------------------------------

makeTagsFor :: IDataType -> [CStmt]
makeTagsFor (IDataType _ cs) = map makeTag cs
 where makeTag (n,_) = cdefine (tag n) (getTag n + 5)

------------------------------------------------------------------------------
-- Symbols
------------------------------------------------------------------------------

--- Which `Payload` (`node.h`) a constructor's `Symbol` should carry -- see
--- this module's own header comment. Every other constructor, and every
--- function, gets `PAYLOAD_NONE`.
boxPayload :: IQName -> CExpr
boxPayload (m,n,_) = case (m,n) of
  ("Prelude","Int")   -> text "PAYLOAD_INT"
  ("Prelude","Char")  -> text "PAYLOAD_CHAR"
  ("Prelude","Float") -> text "PAYLOAD_FLOAT"
  _                   -> text "PAYLOAD_NONE"

symbolName :: IQName -> CName
symbolName n = mangle n ++ "_symbol"

symbolLit :: IQName -> CExpr -> IArity -> CExpr -> CExpr -> CStmt
symbolLit n tagExpr arity payload hnfExpr =
  (text "static Symbol" <+> text (symbolName n)) .=
  carray [ dinit "tag"     tagExpr
         , dinit "arity"   (int arity)
         , dinit "name"    (dquotes (text (toName n)))
         , dinit "payload" payload
         , dinit "hnf"     hnfExpr
         ]

writeConSymbol :: (IQName, IArity) -> CStmt
writeConSymbol (n,a) = symbolLit n (text (tag n)) a (boxPayload n) (text "&CTR_hnf")

writeFunSymbol :: IFunction -> CStmt
writeFunSymbol (IFunction n a _ _ _) =
  symbolLit n (text "FUNCTION_TAG") a (text "PAYLOAD_NONE") (text ('&' : hnf n))

------------------------------------------------------------------------------
-- set_X / make_X: shared child-array plumbing
------------------------------------------------------------------------------

makeArgs :: [Int] -> [(CType,CName)]
makeArgs = map (\v -> ("field", varName v))

--- Every child beyond the first 3 lives in a separately-allocated array
--- (`children[3].a`, `node.h`) -- always set explicitly, either to that
--- allocation or to `NULL`, since `set_X` may be overwriting a node whose
--- previous use left this pointer non-null.
setChildArray :: IArity -> CStmt
setChildArray arity
  | arity > 3 = (root <> text ".n->children[3].a") .= alloc_f (arity - 3)
  | otherwise = (root <> text ".n->children[3].a") .= text "NULL"

--- Assign the constructor/function's real arguments into `root`'s child
--- slots, in the same, direct, forward order the arguments themselves
--- come in (child slot 0 <- argument 1, slot 1 <- argument 2, ...) --
--- matching what `Rice.Codegen.C.ToC`'s `IVarAccess`/`INodeAssign`
--- compilation (`children`) already assumes an index means (the external
--- `icurry` package's own convention, confirmed empirically: forward
--- storage gave the right value, old_rice's reversed-storage convention
--- did not -- see this module's own file header for the incident).
--- `apply` nodes are the one place reversed storage is real and
--- necessary (letting `missing` alone determine which slot a partial
--- application's next argument lands in, `archetecture.md`) -- but that's
--- entirely `runtime.h`'s own hardcoded `set_apply*`/`make_apply*` logic,
--- unrelated to the ordinary constructor/function nodes generated here.
setRealChildren :: IArity -> [CStmt]
setRealChildren arity = zipWith setChild [0 .. arity-1] [1 .. arity]
 where setChild i v = children root [i] .= var v

--- Any of child slots 0,1,2 *not* used by a real argument gets explicitly
--- nulled, for the same "root may be reused, stale pointers" reason as
--- `setChildArray`.
setUnusedChildren :: IArity -> [CStmt]
setUnusedChildren arity = map nullChild [arity .. 2]
 where nullChild i = (children root [i] <> text ".n") .= text "NULL"

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
        setUnusedChildren arity
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
        , symbol root .= (text "&" <> text (symbolName name))
        , missing root .= text "missing"
        , setChildArray arity
        ] ++
        setRealChildren arity ++
        [ creturnExpr root ]
      )
  , text ""
  ]
 where args = makeArgs [1..arity] ++ [("int","missing")]

makeCon :: (IQName, IArity) -> [CStmt]
makeCon (n,a) = makeEntry n a

makeFun :: IFunction -> [CStmt]
makeFun (IFunction n a _ _ _) = makeEntry n a

------------------------------------------------------------------------------
-- set_X_free / make_X_free -- constructors only (narrowing a free
-- variable always narrows it to some *constructor* shape, never a
-- function).
------------------------------------------------------------------------------

setChildFree :: Int -> CStmt
setChildFree i = children root [i] .= call "free_var" []

setConFree :: (IQName, IArity) -> [CStmt]
setConFree (n,a) =
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

makeConFree :: (IQName, IArity) -> [CStmt]
makeConFree (n,a) =
  [ hfunDefn "field" ("make_" ++ mangle n ++ "_free") []
      ( [ text "field root" <> semi
        , (root <> text ".n") .= alloc_n 1
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
