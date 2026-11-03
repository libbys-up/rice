------------------------------------------------------------------------------
--- The `rice` command: parse the options, compile every module the program
--- needs in dependency order, then build and link the executable.
---
--- The pipeline is described in the developer's manual
--- (`src/developers-manual.tex`, "The compiler").
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Main where

import System.Environment (getArgs)
import System.Console.GetOpt
import System.Directory   (createDirectoryIfMissing, doesFileExist,
                           doesDirectoryExist, getDirectoryContents,
                           getModificationTime)
import System.FilePath    (takeDirectory, takeExtension, replaceExtension,
                           takeFileName,
                           (</>), (<.>))
import System.Process     (system, exitWith)
import Data.Time          (ClockTime)
import qualified Data.Map as Map
import Data.List          (nub, last, maximum)
import Data.Char          (toLower, ord)
import Control.Monad      (when, foldM, filterM)
import Text.Pretty        (pPrint)

import FlatCurry.Types                   (Prog (..), FuncDecl (..), Rule (..),
                                          QName)
import FlatCurry.Typed.Types             (TProg, TFuncDecl (..), TRule (..))
import FlatCurry.Typed.Goodies           (tProgTFuncs)
import FlatCurry.Transform.Typed.ExecDet (showTransformRuleDet)
import ICurry.Compiler                   (flatCurry2ICurryWithProgs,
                                          defaultICOptions)

import Rice.Files.Info
import Rice.Frontend          (riceHome, readModule)
import Rice.Files.Replace     (replacePrim, replace)
import Rice.Transform.ANF     (normalize)
import Rice.Transform.Unbox   (unbox)
import Rice.Transform.Untype  (removeTypes)
import Rice.Transform.StrLit  (condenseStrings)
import Rice.Transform.Order   (orderFuns)
import Rice.Optimize.FunTable (FunTable, makeFunTable)
import Rice.Optimize.Inline   (optimizeProg, optimizeRules)
import Rice.Build.Deps        (ModuleGraph, buildModuleGraph, topoSort)
import Rice.Build.Cache       (needsRecompile, readCachedOpt, writeOptIfChanged,
                               cPaths, fcyPath, readCachedFcy,
                               writeFcyIfChanged, writeFileIfChanged)
import Rice.Codegen.FieldReps (FieldRepTable, emptyReps, fieldRepTable,
                               interfaceReps, addLiftedReps, unionReps,
                               lintFieldReps, showFieldReps)
import Rice.Codegen.C.ToH     (toHeader)
import Rice.Codegen.C.ToC     (toSource, writeMain, MainMode (..))
import Rice.Diagnostics       (timeIO, timePure)

main :: IO ()
main = do
  args <- getArgs
  let (opts, files, optErrors) = getOpt RequireOrder optDescrs args
      fileErrors = if length files /= 1
                     then ["Expected exactly one file to compile"]
                     else []
      errors = fileErrors ++ optErrors
  if SHelp `elem` opts
    then putStr (usageInfo usageHeader userOptDescrs)
    else if SHelpDev `elem` opts
    then putStr (usageInfo devHeader devOptDescrs)
    else if not (null errors)
      then do mapM_ putStrLn errors
              exitWith 1
      else compileProgram opts (head files)

--- Prints a progress message, under `--verbose`.
say :: [CompilerOptions] -> String -> IO ()
say opts msg = when (SVerbose `elem` opts) (putStrLn msg)

usageHeader :: String
usageHeader = "Usage: rice [OPTIONS] FILE.curry"

devHeader :: String
devHeader = "Developer options (for working on rice itself):"

--- Compiles `file` and every module it imports, then links the executable.
compileProgram :: [CompilerOptions] -> String -> IO ()
compileProgram opts file = do
  let timing = SCompilerTime `elem` opts
  graph <- buildModuleGraph timing file
  case topoSort graph of
    Left cyc       -> do putStrLn ("Cyclic import involving: " ++ unwords cyc)
                         exitWith 1
    Right modNames -> do
      let rootModule = last modNames
          start      = (Map.empty, [], emptyReps)
      (_, fcys, _) <- timeIO timing "compile all modules"
                        (foldM (run graph rootModule opts) start modNames)
      timeIO timing "build+link executable"
             (buildExecutable opts modNames (externalsOf fcys))

--- Compiles one module, writing its `.h` and `.c`.
---
--- The accumulator holds what we know about the modules compiled so far,
--- which are this module's imports, since `modNames` is in dependency order:
--- their function tables (for inlining), their untyped FlatCurry (ICurry
--- generation needs the boxed `Int`/`Char`/`Float` types `unbox` added to
--- Prelude, which only exist in memory), and their field reps. We return it
--- extended with this module.
---
--- There are two caches. If the module isn't stale, we read its optimized
--- program (`.rtfcy`) instead of optimizing it again. If it isn't stale and
--- no printing option needs the intermediate stages, we also read its
--- untyped FlatCurry (`.rfcy`) and keep the `.h`/`.c` already on disk.
run :: ModuleGraph -> String -> [CompilerOptions]
    -> (FunTable, [Prog], FieldRepTable) -> String
    -> IO (FunTable, [Prog], FieldRepTable)
run graph rootModule opts (importedFT, impFcys, impReps) mname = do
  let imports = Map.findWithDefault (error missingModule) mname graph
      forced  = (has SForceRecompile && mname == rootModule)
                || mname `elem` [n | SForceRecompileModule n <- opts]
  when (has SPrintLoops) (readModule mname >>= showLoops)
  stale <- if forced then return True else needsRecompile mname imports
  optimized <- if stale
    then optimizeModule opts importedFT mname
    else do say opts ("Skipping " ++ mname)
            time "readCachedOpt" (readCachedOpt mname)
  let (_, loopBreakers) = orderFuns optimized
      localFT           = makeFunTable loopBreakers (tProgTFuncs optimized)
      reps              = unionReps (interfaceReps optimized) impReps
  when (has SPrintOptimize) (showFlat optimized)
  (cPath, hPath) <- cPaths mname
  fPath          <- fcyPath mname
  cachesExist    <- fmap and (mapM doesFileExist [cPath, hPath, fPath])
  let inspecting = any has [ SPrintANF, SPrintICurry, SPrintFlatCurryRaw
                           , SPrintC, SPrintFieldReps ]
  fcy <- if stale || inspecting || not cachesExist
    then generateModule opts impFcys reps mname optimized
    else time "readCachedFcy" (readCachedFcy mname)
  return (Map.union localFT importedFT, fcy : impFcys, reps)
 where
  has opt = opt `elem` opts

  time :: String -> IO a -> IO a
  time stage = timeIO (has SCompilerTime) (mname ++ ": " ++ stage)


  missingModule = "Rice.Main.run: " ++ mname ++ " missing from its own module graph"

--- Reads a module's typed FlatCurry and runs the passes up to and including
--- the optimizer, then writes the result to the `.rtfcy` cache.
optimizeModule :: [CompilerOptions] -> FunTable -> String -> IO TProg
optimizeModule opts importedFT mname = do
  say opts ("Compiling " ++ mname)
  prog <- timeIO timing (stage "readModule (stale)") (readModule mname)
  stopIf SStopRaw "before any transform" prog
  strProg <- timePure timing (stage "condenseStrings") (condenseStrings prog)
  printIf SPrintFlatCurry strProg
  stopIf SStopCondense "after condenseStrings" strProg
  unboxed <- timePure timing (stage "unbox") (unbox strProg)
  printIf SPrintUnbox unboxed
  stopIf SStopUnbox "after unbox" unboxed
  replaced <- timeIO timing (stage "replace") $
                if mname == "Prelude"
                  then replacePrim unboxed >>= replace
                  else replace unboxed
  printIf SPrintReplace replaced
  stopIf SStopReplace "after replace" replaced
  let (_, loopBreakers) = orderFuns replaced
      ownFT             = makeFunTable loopBreakers (tProgTFuncs replaced)
      fullFT            = Map.union ownFT importedFT
  result <- if has SNoOptimize
              then return replaced
              else timePure timing (stage "optimize") (optimizeProg fullFT replaced)
  stopIf SStopOptimize "after optimize" result
  when (has STraceOptimize) (mapM_ (traceOptimize fullFT) (tProgTFuncs replaced))
  timeIO timing (stage "writeOptIfChanged") (writeOptIfChanged mname result)
  return result
 where
  has opt     = opt `elem` opts
  timing      = has SCompilerTime
  stage s     = mname ++ ": " ++ s
  printIf opt p = when (has opt) (showFlat p)
  stopIf opt msg p = when (has opt) $ do
    showFlat p
    error ("STOPPED " ++ msg)
  traceOptimize ft (TFunc (_, name) _ _ _ rule) = case rule of
    TExternal _ _ -> return ()
    TRule ps e    -> do
      putStrLn ("== " ++ name ++ " ==")
      let (_, trace, n) = showTransformRuleDet (-1) (optimizeRules ft) ps e
      putStrLn trace
      putStrLn (show n ++ " steps")

--- Runs the passes after the optimizer (ANF, field reps, removing types,
--- ICurry), writes the module's `.rfcy`, `.h` and `.c`, and returns its
--- untyped FlatCurry. `impReps` holds the field reps of every module
--- compiled so far.
generateModule :: [CompilerOptions] -> [Prog] -> FieldRepTable -> String
               -> TProg -> IO Prog
generateModule opts impFcys impReps mname optimized = do
  (cPath, hPath) <- cPaths mname
  anf <- timePure timing (stage "normalize (ANF)") (normalize optimized)
  when (has SPrintANF) (showFlat anf)
  let ownReps = fieldRepTable anf
  when (has SPrintFieldReps) (putStr (showFieldReps mname ownReps))
  when lintReps $
    case lintFieldReps (unionReps ownReps impReps) ownReps anf of
      []   -> return ()
      msgs -> do mapM_ putStrLn msgs
                 error ("field-rep lint: " ++ show (length msgs)
                        ++ " problem(s) in " ++ mname)
  fcy <- timePure timing (stage "removeTypes") (removeTypes anf)
  when (has SPrintFlatCurryRaw) (print fcy)
  timeIO timing (stage "writeFcyIfChanged") (writeFcyIfChanged mname fcy)
  icy <- timeIO timing (stage "flatCurry2ICurryWithProgs")
                (flatCurry2ICurryWithProgs defaultICOptions impFcys fcy)
  when (has SPrintICurry) (showICurry icy)
  createDirectoryIfMissing True (takeDirectory hPath)
  timeIO timing (stage "write .h/.c") $ do
    let codeReps = addLiftedReps ownReps icy
    writeFile hPath (pPrint (toHeader codeReps icy))
    writeFile cPath (pPrint (toSource codeReps icy))
  return fcy
 where
  has opt  = opt `elem` opts
  timing   = has SCompilerTime
  stage s  = mname ++ ": " ++ s
  -- Only modules we regenerate get linted. To lint a cached library
  -- module, force it with --force-recompile-module.
  lintReps = has SLintFieldReps || any (> 0) [n | SDebug n <- opts]

------------------------------------------------------------------------------
-- Building the executable
------------------------------------------------------------------------------

--- Compiles every module's `.c`, the runtime, and a generated `rice-main.c` for
--- the root module (the last in dependency order), and links them into one
--- executable named after the root module. The runtime is in
--- `runtime/` under `riceHome`.
---
--- Each `.c` is compiled to a `.o` in an `obj-<hash>` directory next to it,
--- where the hash is of the compiler and flags (`objDirName`), and only
--- when that `.o` is out of date (`compileObj`). So an unchanged Prelude
--- isn't recompiled, and builds with different flags (`--cflags`,
--- `--debug`, `--gcc`) keep separate objects instead of overwriting the
--- runtime's and Prelude's.
buildExecutable :: [CompilerOptions] -> [String] -> Map.Map String [QName]
                -> IO ()
buildExecutable opts modNames externals = do
  home <- riceHome
  let runtimeDir = home </> "runtime"
      rootModule = last modNames
  extFiles <- externalFiles runtimeDir modNames externals
  cHs <- mapM cPaths modNames
  (_, rootHPath) <- cPaths rootModule
  -- A hierarchical module's header is in a subdirectory (A/B/C.h for
  -- A.B.C), and is included by that path (Rice.Codegen.C.C.cinclude),
  -- so the include directory is the one above it.
  let includeDir m h = iterate takeDirectory h !! (1 + length (filter (== '.') m))
      incDirs        = nub (zipWith includeDir modNames (map snd cHs))
      -- The driver with C's main. No module can be called rice-main, so it
      -- can't clash with a module's .c, even on a case-insensitive file
      -- system, where main.c and a module Main's Main.c are the same file.
      mainPath       = includeDir rootModule rootHPath </> "rice-main.c"
      codeFlags    = ["-std=c11", "-O2"] ++ debugFlag ++ cflags
      incFlags     = map ("-I" ++) (runtimeDir : incDirs)
      runtimeFiles = map (runtimeDir </>) [ "runtime.c", "trail.c", "machine.c"
                                          , "heap.c", "gc.c", "ext.c" ]
      allCFiles    = runtimeFiles ++ extFiles ++ map fst cHs ++ [mainPath]
  writeFileIfChanged mainPath
    (pPrint (writeMain rootModule home (mainModeOpt opts)))
  -- Only the hand-written runtime headers count here. A module's generated
  -- .h is always rewritten together with its .c, so the ordinary .c-vs-.o
  -- check already covers it; counting it here would make any module's
  -- change recompile every object.
  hdrTime <- newestHeaderTime [runtimeDir]
  objs <- mapM (compileObj (SVerbose `elem` opts) cc codeFlags incFlags hdrTime)
               allCFiles
  let cmd = unwords ([cc] ++ objs ++ ["-lm", "-o", rootModule])
  say opts ("Linking: " ++ cmd)
  code <- system cmd
  if code == 0
    then say opts ("Built ./" ++ rootModule)
    else do putStrLn ("Link failed (exit code " ++ show code ++ ")")
            exitWith 1
 where
  cc = if SUseGCC `elem` opts then "gcc" else "clang"
  -- The last --debug wins.
  debugFlag = case [n | SDebug n <- opts] of
    [] -> []
    ns -> ["-DDEBUG=" ++ show (last ns)]
  -- Every --cflags is used, and each can hold several flags.
  cflags = concatMap words [s | SCFlags s <- opts]

--- Each module's external functions, from its untyped FlatCurry. Only the
--- ones the optimizer kept are there, which are the ones the program uses.
externalsOf :: [Prog] -> Map.Map String [QName]
externalsOf fcys = Map.fromList
  [ (m, exts) | Prog m _ _ funs _ <- fcys
              , let exts = [ f | Func f _ _ _ (External _) <- funs ]
              , not (null exts) ]

--- The C files with the externals of the modules in `modNames`:
--- `runtime/ext/M.c` for module `M` (`runtime/ext.h`). If a module has
--- externals but no such file, we stop here and name them, rather than
--- leave the linker to report each one as an undefined symbol.
externalFiles :: FilePath -> [String] -> Map.Map String [QName] -> IO [FilePath]
externalFiles runtimeDir modNames externals = do
  let needed = [ (m, exts) | m <- modNames
                           , Just exts <- [Map.lookup m externals] ]
      file m = runtimeDir </> "ext" </> m <.> "c"
  missing <- filterM (fmap not . doesFileExist . file . fst) needed
  if null missing
    then return (map (file . fst) needed)
    else do
      mapM_ (\(m, exts) -> putStrLn
               ("Rice doesn't implement the external functions of " ++ m
                ++ " (" ++ file m ++ "): " ++ unwords (map snd exts)))
            missing
      exitWith 1

--- Compiles `cFile` to a `.o` in its `obj-<hash>` directory, unless the
--- `.o` is up to date: newer than `cFile` and than `hdrTime`, and built
--- with the same compiler and `codeFlags`, which we record in a `.o.flags`
--- file beside it (the hash alone could collide). The include flags are
--- left out of the record: they differ between programs, but don't change
--- the object. Returns the `.o`.
---
--- The compiler writes a temporary file that's then renamed, so two rice
--- runs building the same object at once can't leave a half-written one.
compileObj :: Bool -> String -> [String] -> [String] -> Maybe ClockTime
           -> FilePath -> IO FilePath
compileObj verbose cc codeFlags incFlags hdrTime cFile = do
  let invocation = unwords (cc : codeFlags)
      objDir     = takeDirectory cFile </> objDirName invocation
      oFile      = objDir </> takeFileName (replaceExtension cFile "o")
      flagsFile  = oFile <.> "flags"
  oExists <- doesFileExist oFile
  current <- if not oExists then return False else do
    oTime     <- getModificationTime oFile
    cTime     <- getModificationTime cFile
    prevFlags <- readIfExists flagsFile
    return (cTime <= oTime
            && maybe True (<= oTime) hdrTime
            && prevFlags == Just invocation)
  if current
    then return oFile
    else do
      createDirectoryIfMissing True objDir
      let tmp = oFile ++ ".$$"  -- the shell's process id
          cmd = unwords ([cc, "-c"] ++ codeFlags ++ incFlags
                         ++ [cFile, "-o", tmp])
      when verbose (putStrLn ("Compiling: " ++ cmd))
      code <- system (cmd ++ " && mv " ++ tmp ++ " " ++ oFile)
      if code == 0
        then do writeFile flagsFile invocation
                return oFile
        else do putStrLn ("Compile failed (exit code " ++ show code ++ "): " ++ cmd)
                exitWith 1
 where
  -- `readFile` is lazy, so we force the whole file here. Otherwise the
  -- handle could still be open when we write `flagsFile` above.
  readIfExists path = do
    exists <- doesFileExist path
    if not exists then return Nothing else do
      s <- readFile path
      length s `seq` return (Just s)

--- The name of the directory for objects built by `invocation` (the
--- compiler and its flags): `obj-` and a hash of it.
objDirName :: String -> String
objDirName invocation = "obj-" ++ show (foldl step 5381 invocation)
 where
  -- djb2, kept to 32 bits
  step h c = (h * 33 + ord c) `mod` 4294967296

--- The newest modification time of the `.h` files directly in `dirs`, or
--- `Nothing` if there aren't any.
newestHeaderTime :: [FilePath] -> IO (Maybe ClockTime)
newestHeaderTime dirs = do
  files <- concat <$> mapM headersIn dirs
  times <- mapM getModificationTime files
  return (if null times then Nothing else Just (maximum times))
 where
  headersIn d = do
    exists <- doesDirectoryExist d
    if not exists then return [] else do
      names <- getDirectoryContents d
      return [d </> n | n <- names, takeExtension n == ".h"]

------------------------------------------------------------------------------
-- Options
------------------------------------------------------------------------------

data CompilerOptions
  -- printing intermediate stages
  = SPrintFlatCurry | SPrintFlatCurryRaw | SPrintUnbox | SPrintReplace
  | SPrintOptimize  | STraceOptimize     | SPrintANF   | SPrintFieldReps
  | SPrintICurry    | SPrintC            | SPrintLoops
  -- stopping after a stage
  | SStopRaw | SStopCondense | SStopUnbox | SStopReplace | SStopOptimize
  -- compiling
  | SNoOptimize | SLintFieldReps | SInteractive | SNoPrelude | SMakeExt
  -- building the executable
  | SUseGCC | SDebug Int | SCFlags String
  -- caching
  | SForceRecompile | SForceRecompileModule String
  -- other
  | SVerbose | SCompilerTime | SHelp | SHelpDev
 deriving (Show, Eq)

--- Parses `--debug`'s argument: one of `runtime/debug.h`'s named levels
--- (low, med, high), or a non-negative number. 0 turns debugging off.
parseDebugLevel :: String -> CompilerOptions
parseDebugLevel s = SDebug $ case map toLower s of
  "low"    -> 1
  "med"    -> 2
  "medium" -> 2
  "high"   -> 3
  other    -> case reads other of
    [(n, "")] | n >= 0 -> n
    _ -> error ("--debug: expected low|med|high or a non-negative "
                ++ "integer, got " ++ show s)

--- The driver the generated `rice-main.c` runs `main` with (see `MainMode`).
mainModeOpt :: [CompilerOptions] -> MainMode
mainModeOpt opts = if SInteractive `elem` opts then Interactive else Standalone

--- Every option rice accepts. `--help` lists only `userOptDescrs`;
--- `--help-dev` lists `devOptDescrs`.
optDescrs :: [OptDescr CompilerOptions]
optDescrs = userOptDescrs ++ devOptDescrs

--- The options for compiling and running Curry programs.
userOptDescrs :: [OptDescr CompilerOptions]
userOptDescrs =
  [ Option []  ["interactive"]     (NoArg SInteractive)       interactiveHelp
  , Option "x" ["gcc"]             (NoArg SUseGCC)            "use GCC instead of clang"
  , Option []  ["cflags"]          (ReqArg SCFlags "FLAGS")   cflagsHelp
  , Option []  ["force-recompile"]        (NoArg SForceRecompile)               forceHelp
  , Option []  ["force-recompile-module"] (ReqArg SForceRecompileModule "MODULE") forceModuleHelp
  , Option "v" ["verbose"]         (NoArg SVerbose)           "say which modules are compiled, and print each C compiler and linker command"
  , Option "h" ["help"]            (NoArg SHelp)              "print this help message and exit"
  , Option []  ["help-dev"]        (NoArg SHelpDev)           "print the developer options and exit"
  ]
 where
  interactiveHelp = "print every value of main, instead of running main as an "
                    ++ "IO action; for REPL front ends"
  cflagsHelp      = "extra space-separated C compiler flags, e.g. "
                    ++ "\"-DOPT_EPOCH_TRAIL=1\"; repeatable"
  forceHelp       = "recompile the module on the command line, ignoring its cache "
                    ++ "(its imports are only rebuilt if stale)"
  forceModuleHelp = "also recompile MODULE (e.g. Prelude), ignoring its cache; "
                    ++ "repeatable"

--- The options for working on rice itself: printing and stopping after
--- the compiler's stages, and debugging the runtime.
devOptDescrs :: [OptDescr CompilerOptions]
devOptDescrs =
  -- printing intermediate stages, in pipeline order
  [ Option "f" ["flatcurry"]       (NoArg SPrintFlatCurry)    "print FlatCurry"
  , Option []  ["fcy"]             (NoArg SPrintFlatCurryRaw) "print FlatCurry raw format"
  , Option "u" ["unbox"]           (NoArg SPrintUnbox)        "print unboxed FlatCurry"
  , Option "r" ["replace"]         (NoArg SPrintReplace)      "print replaced FlatCurry"
  , Option "o" ["optimize"]        (NoArg SPrintOptimize)     "print FlatCurry after optimize, before ANF"
  , Option []  ["trace-optimize"]  (NoArg STraceOptimize)     "print every optimizer rewrite step, per function"
  , Option []  ["printANF"]        (NoArg SPrintANF)          "print code in A-Normal form"
  , Option []  ["print-fieldreps"] (NoArg SPrintFieldReps)    fieldRepsHelp
  , Option "i" ["icurry"]          (NoArg SPrintICurry)       "print ICurry"
  , Option "c" []                  (NoArg SPrintC)            "regenerate the C files (doesn't print them yet)"
  , Option []  ["printloops"]      (NoArg SPrintLoops)        "print loops in call graph"

  -- stopping after a stage
  , Option []  ["stop-raw"]        (NoArg SStopRaw)           "print the untransformed program, then stop"
  , Option []  ["stop-condense"]   (NoArg SStopCondense)      "print condenseStrings's output, then stop"
  , Option []  ["stop-unbox"]      (NoArg SStopUnbox)         "print unbox's output, then stop"
  , Option []  ["stop-replace"]    (NoArg SStopReplace)       "print replace's output, then stop"
  , Option []  ["stop-optimize"]   (NoArg SStopOptimize)      "print optimize's output, then stop"

  -- compiling
  , Option []  ["no-optimize"]     (NoArg SNoOptimize)        "skip Rice.Optimize.Inline"
  , Option []  ["lint-fieldreps"]  (NoArg SLintFieldReps)     lintHelp
  , Option "p" ["noprelude"]       (NoArg SNoPrelude)         "don't include Prelude (not implemented)"
  , Option "e" ["external"]        (NoArg SMakeExt)           "make/overwrite external file (not implemented)"

  -- debugging
  , Option []  ["debug"]           (ReqArg parseDebugLevel "LEVEL") debugHelp
  , Option []  ["compiler-time"]   (NoArg SCompilerTime)      "print how long each compiler stage takes, in ms"
  ]
 where
  fieldRepsHelp   = "print which fields and variables hold raw Int#/Char#/Float# values"
  lintHelp        = "fail the compile if a raw value could reach a pointer slot, "
                    ++ "in every regenerated module (also on with --debug)"
  debugHelp       = "build with runtime debug output: low, med, high, or a number "
                    ++ "(see runtime/debug.h)"
