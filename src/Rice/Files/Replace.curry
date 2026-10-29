module Rice.Files.Replace (replacePrim, replace) where

import FlatCurry.Typed.Goodies  (updQNamesInTProg, updQNamesInTFunc, updTProgTFuncs, 
                                 tFuncName, tProgTFuncs, tProgName, updTRuleExtDecl,
                                 updTFuncTRule, updTRule, trTExpr,
                                 updQNamesInTypeExpr)
import System.Directory         (doesFileExist)
import FlatCurry.Typed.Types    (TProg, TFuncDecl, TExpr (..), TBranchExpr (..),
                                 TPattern (..))
import FlatCurry.Types          (QName)
import System.FilePath          ((</>), (<.>))
import Data.List                (find, isPrefixOf)

import Rice.Transform.StrLit    (condenseStrings)
import Rice.Transform.Unbox     (unbox)
import Rice.Frontend            (riceHome, readModuleFile)

-- `replace_Prim.curry` can't name `Int#` in its source, so it calls the
-- raw types `Int_SH`, `Char_SH` and `Float_SH`. This gives them their names.
rename_SH :: QName -> QName
rename_SH q = case q of
                   ("replace_Prim","Int_SH") -> ("replace_Prim","Int#")
                   ("replace_Prim","Char_SH") -> ("replace_Prim","Char#")
                   ("replace_Prim","Float_SH") -> ("replace_Prim","Float#")
                   _ -> q

--- Replaces Prelude's functions on Int, Char and Float with the versions
--- in `replace/replace_Prim.curry` under `riceHome`, which unbox their arguments
--- and call raw primitives. See the developer's manual, "Replacing
--- Prelude functions".
replacePrim :: TProg -> IO TProg
replacePrim pre = do home <- riceHome
                     let primFile = home </> "replace" </> "replace_Prim" <.> "curry"
                     prim <- readModuleFile primFile
                     let prim_sharp = updTProgTFuncs (map (updTypeQNamesInTFunc rename_SH))
                                        (updQNamesInTProg rename_SH prim)
                     return $ replaceFuncs "Prelude" prim_sharp pre

-- The function of the same name in `rep`, moved into module `name`, or
-- the original function if `rep` doesn't have one.
replaceFunc :: String -> TProg -> TFuncDecl -> TFuncDecl
replaceFunc name rep f = case find (same f) (tProgTFuncs rep) of
                              Just f' -> updName name f'
                              Nothing -> f
  where same f f' = snd (tFuncName f') == snd (tFuncName f)

replaceFuncs :: String -> TProg -> TProg -> TProg
replaceFuncs name rep = updProgExts (replaceName (tProgName rep) name)
                      . addFuncs name rep 
                      . updTProgTFuncs (map (replaceFunc name rep)) 

updProgExts :: (String -> String) -> TProg -> TProg
updProgExts = updTProgTFuncs . map . (updTFuncTRule . updTRuleExtDecl)

replaceName :: String -> String -> String -> String
replaceName from to name
 | length name < length from = name
 | from `isPrefixOf` name    = to ++ drop (length from) name
 | otherwise                 = head name : replaceName from to (tail name)

updName :: String -> TFuncDecl -> TFuncDecl
updName name = updTypeQNamesInTFunc rn . updQNamesInTFunc rn
 where
  -- A module-less name is a string literal (`Rice.Transform.StrLit`), not
  -- something defined anywhere, so it keeps its empty module.
  rn (m,n) = if null m then (m,n) else (name,n)

--- Renames the type names `updQNamesInTFunc` leaves alone: it renames the
--- function's own signature, calls and pattern constructors, but not the
--- type annotations inside the rule -- parameter types, an external's
--- type, and every annotation in the body. `Rice.Codegen.FieldReps` reads
--- those annotations, so a replaced function has to agree with the
--- module it's moved into all the way down.
updTypeQNamesInTFunc :: (QName -> QName) -> TFuncDecl -> TFuncDecl
updTypeQNamesInTFunc f =
  updTFuncTRule (updTRule ty (map (\(v,t) -> (v, ty t))) body id)
 where
  ty   = updQNamesInTypeExpr f
  body = trTExpr (TVarE . ty) (TLit . ty) (TComb . ty) lt fr TOr TCase branch
                 (\e t -> TTyped e (ty t))
  lt bs e = TLet [((v, ty t), x) | ((v, t), x) <- bs] e
  fr vs e = TFree [(v, ty t) | (v, t) <- vs] e
  branch p e = TBranch (pat p) e
  pat p = case p of
    TPattern t c vs -> TPattern (ty t) c [(v, ty t') | (v, t') <- vs]
    TLPattern t l   -> TLPattern (ty t) l

addFuncs :: String -> TProg -> TProg -> TProg
addFuncs name rep p = updTProgTFuncs allFuncs p
 where names      = map (snd . tFuncName) (tProgTFuncs p)
       newFuncs   = [updName name f | f <- tProgTFuncs rep, not (isOld f)]
       allFuncs _ = (tProgTFuncs p) ++ newFuncs
       isOld f    = elem (snd (tFuncName f)) names

--- Replaces functions in module `M` with the ones defined in
--- `replace/replace_M.curry` under `riceHome`, if that file exists, and adds the
--- functions only defined there.
replace :: TProg -> IO TProg
replace p = do let name = tProgName p
               home <- riceHome
               let repFile = home </> "replace" </> "replace_"++name <.> "curry"
               hasRepFile <- doesFileExist repFile
               if not hasRepFile
                then return p
                else do repP <- readModuleFile repFile
                        -- The module being replaced into has already been
                        -- through these; its replacements have to match.
                        let prepped = unbox (condenseStrings repP)
                        return $ replaceFuncs name prepped p
