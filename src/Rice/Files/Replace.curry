module Rice.Files.Replace (replacePrim, replace) where

import System.Environment       (getEnv)
import System.CurryPath         (runModuleActionQuiet)
import FlatCurry.Typed.Files    (readTypedFlatCurry)
import FlatCurry.Typed.Goodies  (updQNamesInTProg, updQNamesInTFunc, updTProgTFuncs, 
                                 tFuncName, tProgTFuncs, tProgName, updTRuleExtDecl,
                                 updTFuncTRule)
import System.Directory         (doesFileExist)
import FlatCurry.Typed.Types    (TProg, TFuncDecl)
import FlatCurry.Types          (QName)
import System.FilePath          ((</>), (<.>))
import Data.List                (find, isPrefixOf)

-- | Replaces the primitive types in the given module with their unboxed versions.
rename_SH :: QName -> QName
rename_SH q = case q of
                   ("replace_Prim","Int_SH") -> ("replace_Prim","Int#")
                   ("replace_Prim","Char_SH") -> ("replace_Prim","Char#")
                   ("replace_Prim","Float_SH") -> ("replace_Prim","Float#")
                   _ -> q

-- replaces the functions that operate directly on primitive values
-- with their unboxed versions.
replacePrim :: TProg -> IO TProg
replacePrim pre = do home <- getEnv "RICEHOME"
                     let primFile = home </> "replace" </> "replace_Prim" <.> "curry"
                     prim <- runModuleActionQuiet readTypedFlatCurry primFile
                     let prim_sharp = updQNamesInTProg rename_SH prim
                     return $ replaceFuncs "Prelude" prim_sharp pre

-- tries to find a function is the replace program with the same name
-- if we find one, then rename all of the names to be the origonal module,
-- otherwise return the origonal function.
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
updName name = updQNamesInTFunc (\(_,n) -> (name,n))

addFuncs :: String -> TProg -> TProg -> TProg
addFuncs name rep p = updTProgTFuncs allFuncs p
 where names      = map (snd . tFuncName) (tProgTFuncs p)
       newFuncs   = [updName name f | f <- tProgTFuncs rep, not (isOld f)]
       allFuncs _ = (tProgTFuncs p) ++ newFuncs
       isOld f    = elem (snd (tFuncName f)) names

-- replaces functions in library lib.curry with functions 
-- defined in $RICEHOME/replace/replace_lib.curry
replace :: TProg -> IO TProg
replace p = do let name = tProgName p
               home <- getEnv "RICEHOME"
               let repFile = home </> "replace" </> "replace_"++name <.> "curry"
               hasRepFile <- doesFileExist repFile
               if not hasRepFile
                then return p
                else do repP <- runModuleActionQuiet readTypedFlatCurry repFile
                        return $ replaceFuncs name repP p
