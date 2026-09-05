module Rice.Main where

import System.Environment (getArgs)
import System.Console.GetOpt
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.Process (system)
import qualified Data.Map as Map
import Data.List (nub, last)
import Control.Monad (when, foldM)
import Text.Pretty (pPrint)

import FlatCurry.Types         (Prog)
import FlatCurry.Typed.Types   (TProg)
import FlatCurry.Typed.Goodies (tProgName, tProgImports, tProgTFuncs)
import ICurry.Compiler (flatCurry2ICurryWithProgs, defaultICOptions)

import Rice.Files.Info
import Rice.Files.Replace (replacePrim, replace)
import Rice.Transform.ANF (normalize)
import Rice.Transform.Unbox (unbox)
import Rice.Transform.Untype (removeTypes)
import Rice.Transform.StrLit (condenseStrings)
import Rice.Transform.Order (orderFuns)
import Rice.Optimize.FunTable (FunTable, makeFunTable)
import Rice.Optimize.Inline (optimizeProg)
import Rice.Build.Deps (buildModuleGraph, topoSort)
import Rice.Build.Cache (needsRecompile, readCachedOpt, writeOptIfChanged, cPaths)
import Rice.Codegen.C.ToH (toHeader)
import Rice.Codegen.C.ToC (toSource, writeMain)

main :: IO ()
main = do args <- getArgs
          let (opts, files, errors') = getOpt RequireOrder optDescrs args
          let errors = if length files /= 1
                        then "Too many files to compile. Pick 1" : errors'
                        else errors'
          if not (null errors)
           then mapM_ putStrLn errors
           else do
             graph <- buildModuleGraph (head files)
             case topoSort graph of
               Left cyc    -> putStrLn $
                 "Cyclic import involving: " ++ unwords cyc
               Right progs -> do
                 _ <- foldM (run opts) (Map.empty, []) progs
                 buildExecutable opts (map tProgName progs)

-- Compiles one module given (a) the FunTable entries of everything
-- already compiled (its own imports, since `progs` is in dependency
-- order) and (b) their FlatCurry `Prog`s -- needed so ICurry generation
-- sees Rice's own synthetic boxed-type declarations for Prelude's
-- Int/Char/Float (added by `unbox`, in memory only) instead of silently
-- re-reading Prelude's untouched interface off disk and failing case
-- completion on a boxed value it doesn't recognize. Returns both,
-- extended with this module's own contribution, for whatever gets
-- compiled next.
run :: [CompilerOptions] -> (FunTable, [Prog]) -> TProg -> IO (FunTable, [Prog])
run opts (importedFT, impFcys) prog =
  do when (SPrintLoops     `elem` opts) (showLoops prog)
     let mname = tProgName prog
     stale <- needsRecompile mname (tProgImports prog)
     optimized <- if stale
       then do
         putStrLn ("Compiling " ++ mname)
         let strProg = condenseStrings prog
         when (SPrintFlatCurry `elem` opts) (showFlat strProg)
         let unboxed = unbox strProg
         when (SPrintUnbox `elem` opts) (showFlat unboxed)
         replaced <- if mname == "Prelude"
                     then replacePrim unboxed >>= replace
                     else replace unboxed
         when (SPrintReplace `elem` opts) (showFlat replaced)
         let (_, ownLoopBreakers) = orderFuns replaced
             ownFT                = makeFunTable ownLoopBreakers (tProgTFuncs replaced)
             result               = optimizeProg (Map.union ownFT importedFT) replaced
         writeOptIfChanged mname result
         return result
       else do
         putStrLn ("Skipping " ++ mname)
         readCachedOpt mname
     let (_, loopBreakers) = orderFuns optimized
         localFT           = makeFunTable loopBreakers (tProgTFuncs optimized)
         ft                = Map.union localFT importedFT
     let anf = normalize optimized
     when (SPrintANF       `elem` opts) (showFlat anf)
     let fcy = removeTypes anf
     when (SPrintFlatCurryRaw `elem` opts) (print fcy)
     icy <- flatCurry2ICurryWithProgs defaultICOptions impFcys fcy
     when (SPrintICurry    `elem` opts) (showICurry icy)
     (cPath, hPath) <- cPaths mname
     createDirectoryIfMissing True (takeDirectory hPath)
     writeFile hPath (pPrint (toHeader icy))
     writeFile cPath (pPrint (toSource icy))
     return (ft, fcy : impFcys)

--- Compile every module's already-written `.c`/`.h` (see `run`, above)
--- plus a freshly generated `main.c` for the root module (the last one in
--- dependency order) into one executable, linked against `runtime/`'s
--- pure-C core (`Rice.Build.Cache`'s buildable core -- see `STATUS.md`'s
--- Phase 0). `runtime/external.c`/`Prelude_external.c` are deliberately
--- *not* on this link line: neither compiles yet (Phase 2's rewrite,
--- `STATUS.md`), so a program can only build here if it never actually
--- calls into one of their `_hnf`s -- true for anything that doesn't use
--- `(=:=)`/`(=:<=)`, file I/O, or the still-stubbed `show`/`read`
--- primitives.
---
--- Assumes it's being run from the Rice project's own root (so
--- `runtime/` resolves relative to the current directory) -- a real
--- installed compiler would need a proper "where is my runtime"
--- resolution (an installed data directory, a `RICE_HOME` environment
--- variable, ...); not solved here, left as a known Phase 1 gap.
buildExecutable :: [CompilerOptions] -> [String] -> IO ()
buildExecutable opts modNames = do
  let rootModule = last modNames
  cHs <- mapM cPaths modNames
  (_, rootHPath) <- cPaths rootModule
  let mainPath = takeDirectory rootHPath </> "main.c"
  writeFile mainPath (pPrint (writeMain rootModule))
  let cFiles  = map fst cHs
      incDirs = nub (map (takeDirectory . snd) cHs)
      cc      = if SUseGCC `elem` opts then "gcc" else "clang"
      cmd     = unwords $
        -- -O2 matters for more than speed here: setExpr's eager
        -- X_hnf(root) calls (Rice.Codegen.C.ToC) are genuine C tail
        -- calls for a tail-recursive Curry function, but nothing
        -- guarantees the C compiler actually elides them into it without
        -- being asked to optimize -- at -O0 every such call grows the C
        -- stack, so a tail-recursive Curry function can still overflow it
        -- on a large enough input, exactly the failure mode this was
        -- meant to avoid.
        [cc, "-std=c11", "-O2"] ++
        map ("-I" ++) ("runtime" : incDirs) ++
        ["runtime/runtime.c", "runtime/stack.c", "runtime/prelude_min.c"] ++
        cFiles ++
        [mainPath, "-lm", "-o", rootModule]
  putStrLn ("Building: " ++ cmd)
  code <- system cmd
  if code == 0
    then putStrLn ("Built ./" ++ rootModule)
    else putStrLn ("Build failed (exit code " ++ show code ++ ")")

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
