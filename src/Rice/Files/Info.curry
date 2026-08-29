module Rice.Files.Info where

import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies (updTProgTExps)
import FlatCurry.Typed.PrettyFixed (ppProg)

import ICurry.Types
import ICurry.Pretty (ppIProg)

import Text.Pretty (pPrint)

import Rice.Transform.Order


-- This is just a module for printing out information about curry programs.
-- A lot of this may be used in compiler flags.

counts :: TProg -> IO ()
counts (TProg _ _ _ fs _) = do putStrLn $ "impl:  " ++ count impl  fs
                               putStrLn $ "def:   " ++ count def   fs
                               putStrLn $ "inst:  " ++ count inst  fs
                               putStrLn $ "other: " ++ count other fs

showLoops :: TProg -> IO ()
showLoops = putStrLn . unlines . map unlines . filter ((>1) . length) . loops

showFlat :: TProg -> IO ()
showFlat = putStrLn .  pPrint . ppProg

showICurry :: IProg -> IO ()
showICurry = putStrLn . pPrint . ppIProg

count :: (TFuncDecl -> Bool) -> [TFuncDecl] -> String
count f = show . length . filter f

impl, inst, def, other :: TFuncDecl -> Bool
impl  (TFunc (_,n) _ _ _ _) = take 6 n == "_impl#"
inst  (TFunc (_,n) _ _ _ _) = take 6 n == "_inst#"
def   (TFunc (_,n) _ _ _ _) = take 5 n == "_def#"
other f = not (inst f || impl f || def f)
