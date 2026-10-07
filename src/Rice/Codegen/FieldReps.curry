------------------------------------------------------------------------------
--- Field representations: for every node child and every local variable,
--- whether it holds a pointer to a node or a raw `Int#`/`Char#`/`Float#`.
---
--- Types are erased before ICurry (`Rice.Transform.Untype`), so this is
--- computed from the typed program at the last point it still exists --
--- after ANF, right before `removeTypes` -- and carried alongside the
--- untyped program as a side table. Variable indices survive into ICurry
--- unchanged (`ICurry.Compiler.toIExpr (Var v) = IVar v`), so `frVars`
--- can be looked up directly from `ToC`. The one variable ICurry invents
--- itself (a fresh one for a non-variable case scrutinee) never appears
--- after full ANF.
---
--- The design and the invariants it relies on are in
--- `src/field-reps-plan.md`.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Codegen.FieldReps
  ( FieldRep (..), FieldRepTable (..)
  , emptyReps, fieldRepOf, fieldRepTable, interfaceReps, unionReps, isRaw
  , addLiftedReps, lintFieldReps, showFieldReps
  ) where

import qualified Data.Map as Map
import Data.Char (isDigit)
import Data.List (intercalate, isPrefixOf)

import FlatCurry.Types (QName, VarIndex, TypeExpr (..), TypeDecl (..),
                        ConsDecl (..), NewConsDecl (..), CombType (..),
                        Literal (..))
import FlatCurry.Typed.Types
import ICurry.Types (IProg (..), IFunction (..), IFuncBody (..), IBlock (..),
                     IAssign (..), IExpr (..))

--- How a single field (node child or local variable) is represented.
--- `RPtr` is a pointer to a node; the rest are raw C values in a
--- `union field`, and say which primitive, since printing needs it.
data FieldRep = RPtr | RInt | RChar | RFloat
  deriving (Eq, Show)

--- The side table for one module.
--- @field frCons constructor fields, for constructors this module declares
--- @field frFuns function parameters, for functions this module defines
---               (externals included)
--- @field frVars every variable bound in each function's body, parameters
---               included
data FieldRepTable = FieldRepTable
  { frCons :: Map.Map QName [FieldRep]
  , frFuns :: Map.Map QName [FieldRep]
  , frVars :: Map.Map QName (Map.Map VarIndex FieldRep)
  }

--- Whether a field holds a raw value rather than a pointer.
isRaw :: FieldRep -> Bool
isRaw r = r /= RPtr

--- The representation of a value of the given type. Only the three raw
--- primitive types are unboxed; everything else, type variables
--- included, is a pointer -- a raw value never instantiates a
--- polymorphic position.
fieldRepOf :: TypeExpr -> FieldRep
fieldRepOf t = case t of
  TCons ("Prelude","Int#")   [] -> RInt
  TCons ("Prelude","Char#")  [] -> RChar
  TCons ("Prelude","Float#") [] -> RFloat
  ForallType _ t'               -> fieldRepOf t'
  _                             -> RPtr

--- Builds the table for one (typed, post-ANF) module.
fieldRepTable :: TProg -> FieldRepTable
fieldRepTable (TProg _ _ types funs _) = FieldRepTable
  { frCons = Map.fromList (concatMap consReps types)
  , frFuns = Map.fromList [(n, paramReps f) | f@(TFunc n _ _ _ _) <- funs]
  , frVars = Map.fromList [(n, varReps r) | TFunc n _ _ _ r <- funs]
  }

--- The part of a module's table other modules need: constructors and
--- function parameters, without per-function variables. Neither depends
--- on ANF, so this can be computed from a cached, optimized `TProg` for a
--- module that isn't being regenerated.
interfaceReps :: TProg -> FieldRepTable
interfaceReps p = (fieldRepTable p) { frVars = Map.empty }

--- The table with nothing in it.
emptyReps :: FieldRepTable
emptyReps = FieldRepTable Map.empty Map.empty Map.empty

--- Combines two tables; on a clash the left one wins.
unionReps :: FieldRepTable -> FieldRepTable -> FieldRepTable
unionReps (FieldRepTable c1 f1 v1) (FieldRepTable c2 f2 v2) =
  FieldRepTable (Map.union c1 c2) (Map.union f1 f2) (Map.union v1 v2)

--- Adds the functions ICurry generation invents. Lifting nested
--- cases/lets/free declarations (`FlatCurry.CaseLifting`, run inside
--- `ICurry.Compiler`) makes new functions named
--- `<top-level function>_<CASE|COMPLEXCASE|LET|FREE><n>`, whose parameters
--- are variables of that top-level function under their original indices.
--- So a lifted function's parameter reps, and its variables, come from
--- its origin's entry in `frVars`. ICurry reads parameter `p` into
--- variable `i` with `IVarAssign i (IVarAccess 0 [p])`, which is how each
--- position is matched to its variable.
addLiftedReps :: FieldRepTable -> IProg -> FieldRepTable
addLiftedReps reps (IProg _ _ _ funs) = foldr add reps funs
 where
  add (IFunction (m, n, _) arity _ _ body) t
    | Map.member (m, n) (frFuns t) = t
    | otherwise = case liftedOrigin n of
        Nothing -> t
        Just o  -> case Map.lookup (m, o) (frVars reps) of
          Nothing   -> t
          Just vars ->
            let ps = paramVars body
                rs = [ maybe RPtr (\i -> Map.findWithDefault RPtr i vars)
                             (lookup p ps)
                     | p <- [0 .. arity - 1] ]
            in t { frFuns = Map.insert (m, n) rs (frFuns t)
                 , frVars = Map.insert (m, n) vars (frVars t) }
  paramVars body = case body of
    IFuncBody (IBlock _ asgns _) ->
      [ (p, i) | IVarAssign i (IVarAccess 0 [p]) <- asgns ]
    IExternal _ -> []

--- The top-level function a lifted function was lifted out of, if its
--- name has the shape `FlatCurry.CaseLifting.genFuncName` gives one.
liftedOrigin :: String -> Maybe String
liftedOrigin n =
  case break (== '_') (reverse n) of
    (sfx, '_' : rest) | isLiftSuffix (reverse sfx) -> Just (reverse rest)
    _                                              -> Nothing
 where
  isLiftSuffix s = any (\k -> k `isPrefixOf` s && isIndex (drop (length k) s))
                       ["CASE", "COMPLEXCASE", "LET", "FREE"]
  isIndex ds = not (null ds) && all isDigit ds

consReps :: TypeDecl -> [(QName, [FieldRep])]
consReps td = case td of
  Type _ _ _ cs                  -> [(c, map fieldRepOf ts) | Cons c _ _ ts <- cs]
  TypeNew _ _ _ (NewCons c _ t)  -> [(c, [fieldRepOf t])]
  TypeSyn _ _ _ _                -> []

--- A rule's parameters carry their own types; an external only has its
--- declared type, so its first `arity` argument types are used. If the
--- declared type has fewer visible arrows than the arity (only possible
--- through an unexpanded type synonym), the remaining parameters are
--- pointers -- a synonym never names a raw type.
paramReps :: TFuncDecl -> [FieldRep]
paramReps (TFunc _ arity _ ty rule) = case rule of
  TRule params _ -> map (fieldRepOf . snd) params
  TExternal _ _  -> take arity (argReps ty ++ repeat RPtr)
 where
  argReps t = case t of
    FuncType a b    -> fieldRepOf a : argReps b
    ForallType _ t' -> argReps t'
    _               -> []

varReps :: TRule -> Map.Map VarIndex FieldRep
varReps rule = case rule of
  TRule params body -> Map.fromList (binders params ++ exprVars body)
  TExternal _ _     -> Map.empty

binders :: [(VarIndex, TypeExpr)] -> [(VarIndex, FieldRep)]
binders = map (\(v,t) -> (v, fieldRepOf t))

exprVars :: TExpr -> [(VarIndex, FieldRep)]
exprVars e = case e of
  TVarE _ _        -> []
  TLit _ _         -> []
  TComb _ _ _ es   -> concatMap exprVars es
  TLet bs b        -> binders (map fst bs) ++ concatMap (exprVars . snd) bs
                      ++ exprVars b
  TFree vs b       -> binders vs ++ exprVars b
  TOr e1 e2        -> exprVars e1 ++ exprVars e2
  TCase _ s bs     -> exprVars s ++ concatMap branchVars bs
  TTyped b _       -> exprVars b
 where
  branchVars (TBranch p b) = patVars p ++ exprVars b
  patVars p = case p of
    TPattern _ _ vs -> binders vs
    TLPattern _ _   -> []

------------------------------------------------------------------------------
-- Lint
------------------------------------------------------------------------------

--- Checks a typed, post-ANF module against the invariants raw values
--- rely on, returning one message per problem (empty means clean).
--- `env` must cover every constructor and function the module refers to,
--- its own included -- the driver accumulates `interfaceReps` of every
--- module compiled so far and adds this module's own table.
---
--- What it checks:
---   * every argument of a call matches the callee's parameter rep;
---   * a partial application neither supplies nor leaves missing a raw
---     parameter (`apply` only ever fills slots with pointers);
---   * nothing raw is a choice alternative, a free variable, or a
---     function's result (a function node is overwritten by its result,
---     which has to be a node) -- externals excepted;
---   * every case scrutinee is a variable (so ICurry never invents one
---     `frVars` doesn't know about); constructor cases scrutinize
---     pointers, literal cases raw values of the literal's own rep;
---   * every variable occurrence and `let` binding agrees with the rep its
---     binder was given;
---   * every literal is raw (`Rice.Transform.Unbox` boxes all of them).
lintFieldReps :: FieldRepTable -> FieldRepTable -> TProg -> [String]
lintFieldReps env own (TProg _ _ _ funs _) = concatMap lintFun funs
 where
  lintFun (TFunc n _ _ _ rule) = case rule of
    TExternal _ _  -> []
    TRule _ body   ->
      let vars = Map.findWithDefault Map.empty n (frVars own)
          msgs = lintBody env vars body
                 ++ [ "returns a raw " ++ show r | let r = exprRep vars body
                                                  , isRaw r ]
      in map (\m -> showQ n ++ ": " ++ m) msgs

lintBody :: FieldRepTable -> Map.Map VarIndex FieldRep -> TExpr -> [String]
lintBody env vars = go
 where
  go e = case e of
    TVarE t v -> case Map.lookup v vars of
      Nothing -> ["variable " ++ show v ++ " has no binder"]
      Just r  -> [ "variable " ++ show v ++ " is bound as " ++ show r
                   ++ " but used at type " ++ show (fieldRepOf t)
                 | r /= fieldRepOf t ]
    TLit t l -> [ "literal " ++ show l ++ " has non-raw type " ++ show t
                | not (isRaw (fieldRepOf t)) ]
    TComb _ ct f args -> callMsgs ct f args ++ concatMap go args
    TLet bs b -> concat [ bindMsg v x ++ go x | ((v, _), x) <- bs ] ++ go b
    TFree vs b -> [ "free variable " ++ show v ++ " is " ++ show r
                  | (v, t) <- vs, let r = fieldRepOf t, isRaw r ]
                  ++ go b
    TOr e1 e2 -> [ "choice alternative is " ++ show r
                 | x <- [e1, e2], let r = exprRep vars x, isRaw r ]
                 ++ go e1 ++ go e2
    TCase _ s bs -> scrutMsgs s bs ++ go s
                    ++ concatMap (\(TBranch _ b) -> go b) bs
    TTyped b _ -> go b

  bindMsg v x =
    let r = exprRep vars x
    in [ "let-bound variable " ++ show v ++ " is "
         ++ show (Map.findWithDefault RPtr v vars)
         ++ " but its expression is " ++ show r
       | Map.findWithDefault RPtr v vars /= r ]

  callMsgs ct f args
    | isStringLit f = []
    | otherwise =
    let table = if isConsCall ct then frCons env else frFuns env
    in case Map.lookup f table of
      Nothing -> ["no field reps known for " ++ callee]
      Just ps ->
        let given   = zip3 [1 ..] (map (exprRep vars) args) ps
            missing = drop (length args) ps
        in [ "argument " ++ show i ++ " of " ++ callee ++ " is " ++ show a
             ++ " but the parameter is " ++ show p
           | (i, a, p) <- given, a /= p ]
           ++ [ "partial application of " ++ callee
                ++ " with raw parameters " ++ show (filter isRaw ps)
              | isPartCall ct, any isRaw ps ]
           ++ [ "call to " ++ callee ++ " has " ++ show (length args)
                ++ " arguments for " ++ show (length ps) ++ " parameters"
              | not (isPartCall ct), not (null missing)
                || length args > length ps ]
   where callee = showQ f

  scrutMsgs s bs = case s of
    TVarE _ v ->
      let r = Map.findWithDefault RPtr v vars
      in concatMap (branchMsg v r) (take 1 bs)
    _ -> ["case scrutinee is not a variable"]

  branchMsg v r (TBranch p _) = case p of
    TPattern _ c _
      | isRaw r -> [ "constructor case on raw variable " ++ show v
                     ++ " (pattern " ++ showQ c ++ ")" ]
      | otherwise -> []
    TLPattern _ l
      | r /= litRep l -> [ "literal case on variable " ++ show v ++ " ("
                           ++ show r ++ ") with a " ++ show (litRep l)
                           ++ " literal" ]
      | otherwise -> []

--- The rep of an expression's value, from its type -- or, for a
--- variable, from its binder, which is what the lint holds it to.
exprRep :: Map.Map VarIndex FieldRep -> TExpr -> FieldRep
exprRep vars e = case e of
  TVarE t v         -> Map.findWithDefault (fieldRepOf t) v vars
  TLit t _          -> fieldRepOf t
  TComb t _ _ _     -> fieldRepOf t
  TLet _ b          -> exprRep vars b
  TFree _ b         -> exprRep vars b
  TOr e1 _          -> exprRep vars e1
  TCase _ _ bs      -> case bs of
                         TBranch _ b : _ -> exprRep vars b
                         []              -> RPtr
  TTyped _ t        -> fieldRepOf t

litRep :: Literal -> FieldRep
litRep l = case l of
  Intc _   -> RInt
  Floatc _ -> RFloat
  Charc _  -> RChar

--- `Rice.Transform.StrLit` encodes a string literal as a 0-ary
--- constructor call named `("", <the string>)`.
isStringLit :: QName -> Bool
isStringLit (m, _) = null m

isConsCall :: CombType -> Bool
isConsCall ct = case ct of
  ConsCall       -> True
  ConsPartCall _ -> True
  _              -> False

isPartCall :: CombType -> Bool
isPartCall ct = case ct of
  FuncPartCall _ -> True
  ConsPartCall _ -> True
  _              -> False

showQ :: QName -> String
showQ (m, n) = m ++ "." ++ n

--- A readable dump of the table (`--print-fieldreps`). Only entries with
--- at least one raw field are listed -- everything else is all pointers,
--- which is the default -- followed by a count of what was left out.
showFieldReps :: String -> FieldRepTable -> String
showFieldReps mname (FieldRepTable cons funs vars) = unlines $
  [ "== field reps: " ++ mname ++ " ==" ]
  ++ section "constructors" (rawEntries cons)
  ++ section "functions"    (rawEntries funs)
  ++ section "raw variables"
       [ (n, showVars vs) | (n, m) <- Map.toList vars
                          , let vs = filter (isRaw . snd) (Map.toList m)
                          , not (null vs) ]
  ++ [ show (Map.size cons) ++ " constructors, " ++ show (Map.size funs)
       ++ " functions; unlisted entries are all RPtr" ]
 where
  rawEntries m = [ (n, "[" ++ intercalate ", " (map show rs) ++ "]")
                 | (n, rs) <- Map.toList m, any isRaw rs ]
  showVars vs = unwords [ show v ++ ":" ++ show r | (v, r) <- vs ]
  section title es
    | null es   = []
    | otherwise = (title ++ ":") : [ "  " ++ showQ n ++ " " ++ s | (n, s) <- es ]
