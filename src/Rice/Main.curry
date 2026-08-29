module Rice.Main where

import System.Environment (getArgs)
import System.Console.GetOpt

import FlatCurry.Typed.Files (readTypedFlatCurry)
import FlatCurry.Typed.Goodies (tProgName)
import ICurry.Compiler (flatCurry2ICurry,defaultICOptions)
import Control.Monad (when)

import Rice.Files.Info
import Rice.Files.Replace (replacePrim, replace)
import Rice.Transform.ANF (normalize)
import Rice.Transform.Unbox (unbox)
import Rice.Transform.Untype (removeTypes)
import Rice.Transform.StrLit (condenseStrings)

main :: IO ()
main = do args <- getArgs
          let (opts, files, errors') = getOpt RequireOrder optDescrs args
          let errors = if length files /= 1
                        then "Too many files to compile. Pick 1" : errors'
                        else errors'
          if not (null errors)
           then mapM_ putStrLn errors
           else readTypedFlatCurry (head files) >>= run opts

run opts prog = do when (SPrintLoops     `elem` opts) (showLoops prog)
                   --when (SPrintFlatCurry `elem` opts) (showFlat prog)
                   let strProg = condenseStrings prog
                   when (SPrintFlatCurry `elem` opts) (showFlat strProg)
                   let unboxed = unbox strProg
                   when (SPrintUnbox `elem` opts) (showFlat unboxed)
                   replaced <- if tProgName prog == "Prelude" 
                               then replacePrim unboxed >>= replace
                               else replace unboxed
                   when (SPrintReplace `elem` opts) (showFlat replaced) 
                   let anf = normalize replaced
                   when (SPrintANF       `elem` opts) (showFlat anf)
                   let fcy = removeTypes anf
                   when (SPrintFlatCurryRaw `elem` opts) (print fcy)
                   icy <- flatCurry2ICurry defaultICOptions fcy
                   when (SPrintICurry    `elem` opts) (showICurry icy)
          

data CompilerOptions = SPrintFlatCurry | SPrintReplace  |
                       SPrintFlatCurryRaw |
                       SPrintUnbox     | SPrintICurry   |
                       SPrintC         | SMakeExt       |
                       SNoPrelude      | SUseGCC        |
                       SPrintLoops      | SPrintANF
 deriving(Show, Eq)

optDescrs :: [OptDescr CompilerOptions]
optDescrs = [
  Option []  ["printloops"] (NoArg SPrintLoops)      "print loops in call graph",
  Option []  ["printANF"]   (NoArg SPrintANF)        "print code in A-Normal form",
  Option "f" ["flatcurry"]  (NoArg SPrintFlatCurry)  "print FlatCurry",
  Option []  ["fcy"]        (NoArg SPrintFlatCurryRaw) "print FlatCurry raw format",
  Option "r" ["replace"]    (NoArg SPrintReplace)   "print replaced FlatCurry",
  Option "u" ["unbox"]      (NoArg SPrintUnbox)     "print unboxed FlatCurry",
  Option "i" ["icurry"]     (NoArg SPrintICurry)    "print ICurry",
  Option "c" []             (NoArg SPrintC)         "print C files",
  Option "e" ["external"]   (NoArg SMakeExt)        "make/overwrite external file",
  Option "p" ["noprelude"]  (NoArg SNoPrelude)      "don't include Prelude (for testing)",
  Option "x" ["gcc"]        (NoArg SUseGCC)         "Use GCC instead of clang"]
