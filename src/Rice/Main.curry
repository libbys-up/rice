module Rice.Main where

import System.Environment (getArgs, getEnv)
import System.Console.GetOpt
import System.Directory (createDirectoryIfMissing, doesFileExist,
                          doesDirectoryExist, getDirectoryContents,
                          getModificationTime)
import System.FilePath (takeDirectory, takeExtension, replaceExtension,
                         (</>), (<.>))
import System.Process (system)
import Data.Time (ClockTime)
import qualified Data.Map as Map
import Data.List (nub, last, maximum)
import Data.Char (toLower)
import Control.Monad (when, foldM)
import Text.Pretty (pPrint)

import FlatCurry.Types         (Prog)
import FlatCurry.Typed.Goodies (tProgTFuncs, tFuncBody, tFuncName)
import FlatCurry.Typed.Files   (readTypedFlatCurry)
import FlatCurry.Transform.Typed.ExecDet (showTransformExprDet)
import ICurry.Compiler (flatCurry2ICurryWithProgs, defaultICOptions)

import Rice.Files.Info
import Rice.Files.Replace (replacePrim, replace)
import Rice.Transform.ANF (normalize)
import Rice.Transform.Unbox (unbox)
import Rice.Transform.Untype (removeTypes)
import Rice.Transform.StrLit (condenseStrings)
import Rice.Transform.Order (orderFuns)
import Rice.Optimize.FunTable (FunTable, makeFunTable)
import Rice.Optimize.Inline (optimizeProg, optimizeRules)
import Rice.Build.Deps (ModuleGraph, buildModuleGraph, topoSort)
import Rice.Build.Cache (needsRecompile, readCachedOpt, writeOptIfChanged, cPaths,
                          fcyPath, readCachedFcy, writeFcyIfChanged,
                          writeFileIfChanged)
import Rice.Codegen.FieldReps (FieldRepTable, emptyReps, fieldRepTable, interfaceReps,
                                addLiftedReps,
                                unionReps, lintFieldReps, showFieldReps)
import Rice.Codegen.C.ToH (toHeader)
import Rice.Codegen.C.ToC (toSource, writeMain, StackSize (..), MainMode (..))
import Rice.Diagnostics (timeIO, timePure)

main :: IO ()
main = do args <- getArgs
          let (opts, files, errors') = getOpt RequireOrder optDescrs args
          if SHelp `elem` opts
           then putStrLn (usageInfo usageHeader optDescrs)
           else do
             let errors = if length files /= 1
                           then "Too many files to compile. Pick 1" : errors'
                           else errors'
             if not (null errors)
              then mapM_ putStrLn errors
              else do
                let timing = SCompilerTime `elem` opts
                graph <- buildModuleGraph timing (head files)
                case topoSort graph of
                  Left cyc    -> putStrLn $
                    "Cyclic import involving: " ++ unwords cyc
                  Right modNames -> do
                    let rootModule = last modNames
                    _ <- timeIO timing "compile all modules"
                           (foldM (run graph rootModule opts) (Map.empty, [], emptyReps) modNames)
                    timeIO timing "build+link executable"
                      (buildExecutable opts modNames)

usageHeader :: String
usageHeader = "Usage: rice [OPTIONS] FILE.curry"

-- Compiles one module (by name -- `graph` has its imports already, and
-- its `TProg` is only fetched here if it turns out to actually need
-- recompiling; see `Rice.Build.Deps.buildModuleGraph`) given (a) the
-- FunTable entries of everything already compiled (its own imports,
-- since `modNames` is in dependency order) and (b) their FlatCurry
-- `Prog`s -- needed so ICurry generation sees Rice's own synthetic
-- boxed-type declarations for Prelude's Int/Char/Float (added by
-- `unbox`, in memory only) instead of silently re-reading Prelude's
-- untouched interface off disk and failing case completion on a boxed
-- value it doesn't recognize. Returns both, extended with this module's
-- own contribution, for whatever gets compiled next.
run :: ModuleGraph -> String -> [CompilerOptions]
    -> (FunTable, [Prog], FieldRepTable) -> String
    -> IO (FunTable, [Prog], FieldRepTable)
run graph rootModule opts (importedFT, impFcys, impReps) mname =
  do let timing  = SCompilerTime `elem` opts
         imports = Map.findWithDefault
                     (error ("Rice.Main.run: " ++ mname ++ " missing from its own module graph"))
                     mname graph
         forcedModules = [n | SForceRecompileModule n <- opts]
         forced  = (SForceRecompile `elem` opts && mname == rootModule)
                   || mname `elem` forcedModules
     -- `--printloops` is the only thing here that needs the raw,
     -- untransformed TProg regardless of staleness -- everything else
     -- either only needs `mname`/`imports` (both already known, no
     -- parse required -- see `Rice.Build.Deps.buildModuleGraph`) or,
     -- in the `stale` branch below, fetches the real TProg itself right
     -- where it's actually needed.
     when (SPrintLoops `elem` opts) (readTypedFlatCurry mname >>= showLoops)
     stale <- if forced
                then return True
                else needsRecompile mname imports
     optimized <- if stale
       then do
         putStrLn ("Compiling " ++ mname)
         prog <- timeIO timing (mname ++ ": readTypedFlatCurry (stale)") (readTypedFlatCurry mname)
         when (SStopRaw `elem` opts) $ do
           showFlat prog
           error "STOPPED before any transform (--stop-raw diagnostic)"
         strProg <- timePure timing (mname ++ ": condenseStrings") (condenseStrings prog)
         when (SPrintFlatCurry `elem` opts) (showFlat strProg)
         when (SStopCondense `elem` opts) $ do
           showFlat strProg
           error "STOPPED after condenseStrings (--stop-condense diagnostic)"
         unboxed <- timePure timing (mname ++ ": unbox") (unbox strProg)
         when (SPrintUnbox `elem` opts) (showFlat unboxed)
         when (SStopUnbox `elem` opts) $ do
           showFlat unboxed
           error "STOPPED after unbox (--stop-unbox diagnostic)"
         replaced <- timeIO timing (mname ++ ": replace") $
           if mname == "Prelude"
           then replacePrim unboxed >>= replace
           else replace unboxed
         when (SPrintReplace `elem` opts) (showFlat replaced)
         when (SStopReplace `elem` opts) $ do
           showFlat replaced
           error "STOPPED after replace (--stop-replace diagnostic)"
         let (_, ownLoopBreakers) = orderFuns replaced
             ownFT                = makeFunTable ownLoopBreakers (tProgTFuncs replaced)
             fullFT               = Map.union ownFT importedFT
         result <- if SNoOptimize `elem` opts
                     then return replaced
                     else timePure timing (mname ++ ": optimize") (optimizeProg fullFT replaced)
         when (SStopOptimize `elem` opts) $ do
           showFlat result
           error "STOPPED after optimize (--stop-optimize diagnostic)"
         when (STraceOptimize `elem` opts) $
           mapM_ (\f -> do
                    putStrLn ("== " ++ snd (tFuncName f) ++ " ==")
                    let (_, trace, n) = showTransformExprDet (-1)
                          (optimizeRules fullFT) (tFuncBody f)
                    putStrLn trace
                    putStrLn (show n ++ " steps"))
                 (tProgTFuncs replaced)
         timeIO timing (mname ++ ": writeOptIfChanged") (writeOptIfChanged mname result)
         return result
       else do
         putStrLn ("Skipping " ++ mname)
         timeIO timing (mname ++ ": readCachedOpt") (readCachedOpt mname)
     let (_, loopBreakers) = orderFuns optimized
         localFT           = makeFunTable loopBreakers (tProgTFuncs optimized)
         ft                = Map.union localFT importedFT
         reps              = unionReps (interfaceReps optimized) impReps
     when (SPrintOptimize `elem` opts) (showFlat optimized)
     (cPath, hPath) <- cPaths mname
     fPath           <- fcyPath mname
     -- Below (normalize/removeTypes/ICurry-generation/.h+.c-writing) is
     -- exactly as expensive to redo as re-optimizing was -- for Prelude,
     -- ANF normalization alone runs ~7s and the .h/.c write another
     -- ~10s (--compiler-time will show this). `stale` (computed above,
     -- already cascades correctly through imports -- see
     -- `Rice.Build.Cache.needsRecompile`) tells us `optimized` is
     -- unchanged from last time, which means this stage's output would
     -- be byte-identical too, so skip it and read the cached
     -- `.rfcy` instead -- unless a diagnostic flag needs the
     -- intermediate value materialized to print it, or a cache file
     -- is simply missing (e.g. upgrading from a build that predates
     -- the `.rfcy` cache).
     -- Linting only covers modules that get regenerated: an unchanged
     -- module's result can't have changed either. To lint a cached
     -- library module, force it (`--force-recompile-module`).
     let lintReps = SLintFieldReps `elem` opts
                    || any (> 0) [n | SDebug n <- opts]
         inspecting = or [f `elem` opts |
                          f <- [SPrintANF, SPrintICurry, SPrintFlatCurryRaw, SPrintC,
                                SPrintFieldReps]]
     cachesExist <- fmap and (mapM doesFileExist [cPath, hPath, fPath])
     let regen = stale || inspecting || not cachesExist
     fcy <- if regen
       then do
         anf <- timePure timing (mname ++ ": normalize (ANF)") (normalize optimized)
         when (SPrintANF `elem` opts) (showFlat anf)
         let ownReps = fieldRepTable anf
         when (SPrintFieldReps `elem` opts)
           (putStr (showFieldReps mname ownReps))
         when lintReps $
           case lintFieldReps (unionReps ownReps reps) ownReps anf of
             []   -> return ()
             msgs -> do mapM_ putStrLn msgs
                        error ("field-rep lint: " ++ show (length msgs)
                               ++ " problem(s) in " ++ mname)
         newFcy <- timePure timing (mname ++ ": removeTypes") (removeTypes anf)
         when (SPrintFlatCurryRaw `elem` opts) (print newFcy)
         timeIO timing (mname ++ ": writeFcyIfChanged") (writeFcyIfChanged mname newFcy)
         icy <- timeIO timing (mname ++ ": flatCurry2ICurryWithProgs")
                  (flatCurry2ICurryWithProgs defaultICOptions impFcys newFcy)
         when (SPrintICurry `elem` opts) (showICurry icy)
         createDirectoryIfMissing True (takeDirectory hPath)
         timeIO timing (mname ++ ": write .h/.c") $ do
           writeFile hPath (pPrint (toHeader (addLiftedReps ownReps icy) icy))
           writeFile cPath (pPrint (toSource icy))
         return newFcy
       else timeIO timing (mname ++ ": readCachedFcy") (readCachedFcy mname)
     return (ft, fcy : impFcys, reps)

--- Compile every module's already-written `.c`/`.h` (see `run`, above)
--- plus a freshly generated `main.c` for the root module (the last one in
--- dependency order) into one executable, linked against `runtime/`'s
--- pure-C core (`Rice.Build.Cache`'s buildable core -- see `STATUS.md`'s
--- Phase 0) plus `runtime/prelude.c` (Phase 2's rewrite of the old,
--- never-actually-linked `external.c`/`Prelude_external.c` -- see
--- `STATUS.md`). A program can still fail to link here if it calls into
--- one of the small number of primitives `prelude.c` only stubs (`catch`,
--- `ensureNotFree`, file I/O, `read*Literal`) -- everything else,
--- including `(=:=)`/`(=:<=)`, is a real implementation now.
---
--- Resolves `runtime/` via `$RICEHOME` (`getEnv`, same convention
--- `Rice.Files.Replace` already uses for `$RICEHOME/replace/`), so this
--- works from any current directory as long as `RICEHOME` points at the
--- Rice project's own root.
---
--- Each `.c` is compiled to its own `.o` (`compileObj`, cached -- see
--- there), right next to it, and only the (much cheaper) link step
--- always runs. This is what makes an unchanged Prelude.c/.h (now
--- skipped entirely on a cache hit -- see `run`, above) actually pay
--- off at the executable-build stage too: previously every `rice`
--- invocation recompiled all of runtime/'s C core plus every module's
--- generated C from scratch, dwarfing however cheap the Curry-side
--- pipeline above got.
buildExecutable :: [CompilerOptions] -> [String] -> IO ()
buildExecutable opts modNames = do
  home <- getEnv "RICEHOME"
  let runtimeDir = home </> "runtime"
  let rootModule = last modNames
  cHs <- mapM cPaths modNames
  (_, rootHPath) <- cPaths rootModule
  let mainPath = takeDirectory rootHPath </> "main.c"
  writeFileIfChanged mainPath
    (pPrint (writeMain rootModule (stackSizeOpt opts) (mainModeOpt opts)))
  let cFiles  = map fst cHs
      incDirs = nub (map (takeDirectory . snd) cHs)
      cc      = if SUseGCC `elem` opts then "gcc" else "clang"
      -- runtime/debug.h gates its leveled debug()/debug_expr()/etc.
      -- macros behind a `DEBUG` level (LOW=1/MED=2/HIGH=3, or any plain
      -- int); last --debug wins if given more than once, matching how
      -- getOpt folds repeated flags elsewhere.
      debugFlag = case [n | SDebug n <- opts] of
        [] -> []
        ns -> ["-DDEBUG=" ++ show (last ns)]
      -- Raw passthrough to the C compiler -- e.g. -DOPT_EPOCH_TRAIL=1 to
      -- flip one of runtime.h's independent backtracking-optimization
      -- flags (src/backtracking-optimizations.md) away from its default
      -- for benchmarking, without editing runtime.h itself. All
      -- occurrences concatenate (each --cflags may itself list more than
      -- one flag), unlike --debug's last-one-wins.
      cflags = concatMap words [s | SCFlags s <- opts]
      -- -O2 matters for more than speed here: setExpr's eager
      -- X_hnf(root) calls (Rice.Codegen.C.ToC) are genuine C tail
      -- calls for a tail-recursive Curry function, but nothing
      -- guarantees the C compiler actually elides them into it without
      -- being asked to optimize -- at -O0 every such call grows the C
      -- stack, so a tail-recursive Curry function can still overflow it
      -- on a large enough input, exactly the failure mode this was
      -- meant to avoid.
      compileFlags = ["-std=c11", "-O2"] ++ debugFlag ++ cflags ++
                     map ("-I" ++) (runtimeDir : incDirs)
      allCFiles = [runtimeDir </> "runtime.c", runtimeDir </> "stack.c",
                   runtimeDir </> "machine.c",
                   runtimeDir </> "prelude.c"] ++ cFiles ++ [mainPath]
  -- Only runtimeDir's headers (runtime.h/debug.h/node.h/memory.h/stack.h
  -- -- hand-edited, not regenerated by Rice) go into the coarse global
  -- bound: every object includes at least one of them (Rice.Codegen.C.
  -- {ToC,ToH}), and nothing else would ever notice one of them changing.
  -- incDirs' per-module *generated* .h files are deliberately excluded
  -- here -- Module.c and Module.h are always rewritten together
  -- whenever that module regenerates (which already cascades correctly
  -- through imports via `run`'s `.rtfcy` staleness check), so their own
  -- ordinary .c-vs-.o mtime comparison already catches it; folding them
  -- into this global bound too would mean recompiling *any* module
  -- invalidates *every* object, including Prelude's and runtime/'s --
  -- exactly the cost this cache exists to avoid. (Found by testing:
  -- touching just one module's source was invalidating the whole
  -- project's .o files before this fix.)
  hdrTime <- newestHeaderTime [runtimeDir]
  objs <- mapM (compileObj cc compileFlags hdrTime) allCFiles
  let cmd = unwords ([cc] ++ objs ++ ["-lm", "-o", rootModule])
  putStrLn ("Linking: " ++ cmd)
  code <- system cmd
  if code == 0
    then putStrLn ("Built ./" ++ rootModule)
    else putStrLn ("Link failed (exit code " ++ show code ++ ")")

--- Compile `cFile` to its `.o` (same directory, `.o` extension in place
--- of `.c`) with `cc`/`flags`, unless it's already up to date: the `.o`
--- exists, is newer than `cFile`, newer than `hdrTime` (from
--- `newestHeaderTime [runtimeDir]` at the call site -- the hand-edited
--- runtime headers every object includes; deliberately coarse, since we
--- don't track which object includes which of *those*, but deliberately
--- excludes per-module generated headers, whose staleness the ordinary
--- `.c`-vs-`.o` check below already covers -- see the call site's own
--- comment), and was last built with this exact same `cc`/`flags`
--- (recorded in a `.o.flags` sidecar) -- so e.g. adding `--debug=high`
--- after a plain build can't silently relink against a stale, non-debug
--- object. Returns the `.o` path either way, to feed straight into the
--- link command.
compileObj :: String -> [String] -> Maybe ClockTime -> FilePath -> IO FilePath
compileObj cc flags hdrTime cFile = do
  let oFile      = replaceExtension cFile "o"
      flagsFile  = oFile <.> "flags"
      invocation = unwords (cc : flags)
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
      let cmd = unwords ([cc, "-c"] ++ flags ++ [cFile, "-o", oFile])
      putStrLn ("Compiling: " ++ cmd)
      code <- system cmd
      if code == 0
        -- Plain `writeFile`, not `writeFileIfChanged`: we're already
        -- committed to recording the flags used for this compile, so
        -- there's nothing to gain from comparing against the old
        -- content first -- and doing so would mean two separate reads
        -- of `flagsFile` in one `compileObj` call (this one plus
        -- `readIfExists` above), which in practice raced with this
        -- very write and failed with "resource busy (file is locked)"
        -- until this was changed to a single forced read.
        then do writeFile flagsFile invocation
                return oFile
        else error ("Compile failed (exit code " ++ show code ++ "): " ++ cFile)
 where
  -- Forces the content immediately (`length s \`seq\``, same trick
  -- `Rice.Build.Cache.writeFileIfChanged` uses) rather than returning a
  -- lazy `readFile` thunk -- otherwise this handle can still be open
  -- (unforced) when we later try to write the same path above.
  readIfExists path = do
    exists <- doesFileExist path
    if not exists then return Nothing else do
      s <- readFile path
      length s `seq` return (Just s)

--- Newest modification time among every `*.h` file directly inside
--- `dirs` (no recursion -- `runtime/` and each module's own cache
--- directory are both flat), or `Nothing` if there are none. See
--- `compileObj`'s use of this as a coarse object-staleness bound.
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

data CompilerOptions = SPrintFlatCurry | SPrintReplace  |
                       SPrintFlatCurryRaw |
                       SPrintUnbox     | SPrintICurry   |
                       SPrintC         | SMakeExt       |
                       SNoPrelude      | SUseGCC        |
                       SPrintLoops      | SPrintANF     | SPrintFieldReps |
                       SLintFieldReps   |
                       SNoOptimize      | SStopReplace  |
                       SStopCondense    | SStopUnbox    |
                       SStopRaw         | SStopOptimize | SDebug Int   |
                       SCFlags String   | SPrintOptimize |
                       STraceOptimize   | SForceRecompile |
                       SForceRecompileModule String |
                       SCompilerTime    | SHelp     |
                       SStackSize StackSize | SInteractive
 deriving(Show, Eq)

--- Parses --debug's argument into an SDebug level: runtime/debug.h's
--- named levels (low/med/high, case-insensitive, matching its
--- LOW/MED/HIGH macros) or a plain non-negative integer (0 disables it,
--- same as omitting --debug; anything above HIGH's 3 is accepted too,
--- since debug.h's `DEBUG >= level` checks impose no upper bound).
parseDebugLevel :: String -> CompilerOptions
parseDebugLevel s = SDebug $ case map toLower s of
  "low"    -> 1
  "med"    -> 2
  "medium" -> 2
  "high"   -> 3
  other    -> case reads other of
    [(n, "")] | n >= 0 -> n
    _ -> error ("--debug: expected low|med|high or a non-negative " ++
                "integer, got " ++ show s)

--- Parses --stack-size's argument: max|unlimited (case-insensitive --
--- request whatever the OS's own hard limit allows; see runtime.c's
--- set_stack_size_max), or a positive integer number of megabytes.
parseStackSize :: String -> CompilerOptions
parseStackSize s = SStackSize $ case map toLower s of
  "max"       -> StackSizeMax
  "unlimited" -> StackSizeMax
  other       -> case reads other of
    [(n, "")] | n > 0 -> StackSizeMB n
    _ -> error ("--stack-size: expected max|unlimited or a positive " ++
                "integer (megabytes), got " ++ show s)

--- The stack-size setting `buildExecutable` passes to `writeMain` --
--- last `--stack-size` wins if given more than once, matching --debug's
--- own convention; `Nothing` (no flag at all) leaves generated `main()`
--- exactly as it was before this flag existed, no rlimit call at all.
stackSizeOpt :: [CompilerOptions] -> Maybe StackSize
stackSizeOpt opts = case [s | SStackSize s <- opts] of
  [] -> Nothing
  ss -> Just (last ss)

--- Which top-level driver `writeMain` (Rice.Codegen.C.ToC) generates --
--- `Standalone` (the default, no flag needed) for an ordinary program's
--- `main :: IO _`, run exactly once; `Interactive` (`--interactive`) for
--- a REPL-style front end's generated goal-evaluation module, which wants
--- every solution `nf_all` can backtrack into -- see `MainMode`'s own
--- comment for the full reasoning.
mainModeOpt :: [CompilerOptions] -> MainMode
mainModeOpt opts = if SInteractive `elem` opts then Interactive else Standalone

optDescrs :: [OptDescr CompilerOptions]
optDescrs = [
  Option []  ["printloops"] (NoArg SPrintLoops)      "print loops in call graph",
  Option []  ["printANF"]   (NoArg SPrintANF)        "print code in A-Normal form",
  Option "f" ["flatcurry"]  (NoArg SPrintFlatCurry)  "print FlatCurry",
  Option []  ["fcy"]        (NoArg SPrintFlatCurryRaw) "print FlatCurry raw format",
  Option "r" ["replace"]    (NoArg SPrintReplace)   "print replaced FlatCurry",
  Option "u" ["unbox"]      (NoArg SPrintUnbox)     "print unboxed FlatCurry",
  Option "i" ["icurry"]     (NoArg SPrintICurry)    "print ICurry",
  Option []  ["print-fieldreps"] (NoArg SPrintFieldReps)
                                                     "print which fields/variables hold raw Int#/Char#/Float# values (see src/field-reps-plan.md)",
  Option []  ["lint-fieldreps"] (NoArg SLintFieldReps)
                                                     "fail the compile if raw values could reach a pointer slot, in every module regenerated (also on with --debug)",
  Option "c" []             (NoArg SPrintC)         "print C files",
  Option "e" ["external"]   (NoArg SMakeExt)        "make/overwrite external file",
  Option "p" ["noprelude"]  (NoArg SNoPrelude)      "don't include Prelude (for testing)",
  Option "x" ["gcc"]        (NoArg SUseGCC)         "Use GCC instead of clang",
  Option []  ["debug"]      (ReqArg parseDebugLevel "LEVEL")
                                                     "build with runtime debug output (low|med|high, or a number; see runtime/debug.h)",
  Option []  ["cflags"]     (ReqArg SCFlags "FLAGS")
                                                     "extra, space-separated flags passed straight to the C compiler (e.g. \"-DOPT_EPOCH_TRAIL=1\"; repeatable)",
  Option []  ["stack-size"] (ReqArg parseStackSize "SIZE")
                                                     "raise the built program's own stack limit at startup, up to the OS's hard cap (megabytes, or max|unlimited; helps genuine non-tail recursion OPT_TAIL_JUMP can't -- see backtracking-optimizations.md)",
  Option "o" ["optimize"]   (NoArg SPrintOptimize)  "print FlatCurry after optimize, before ANF",
  Option []  ["trace-optimize"] (NoArg STraceOptimize) "print every optimizer rewrite step, per function (for testing)",
  Option []  ["no-optimize"](NoArg SNoOptimize)     "skip Rice.Optimize.Inline (for testing)",
  Option []  ["force-recompile"](NoArg SForceRecompile)
                                                     "recompile+reoptimize the module given on the command line, ignoring its .rtfcy cache (its imports are still only rebuilt if stale; see --force-recompile-module)",
  Option []  ["force-recompile-module"] (ReqArg SForceRecompileModule "MODULE")
                                                     "also force-recompile MODULE (e.g. a stdlib module like Prelude) regardless of its .rtfcy cache; repeatable",
  Option []  ["compiler-time"] (NoArg SCompilerTime) "print how long each compiler stage takes (TIME lines, in ms)",
  Option []  ["interactive"](NoArg SInteractive)    "compile a REPL-style goal-evaluator instead of a standalone executable: print every solution main can backtrack into (nf_all), instead of running an IO main exactly once (run_io) -- for curry-repl-style front ends, not ordinary programs",
  Option "h" ["help"]        (NoArg SHelp)          "print this help message and exit",
  Option []  ["stop-replace"](NoArg SStopReplace)   "force+print replace's output then stop (for testing)",
  Option []  ["stop-condense"](NoArg SStopCondense) "force+print condenseStrings's output then stop (for testing)",
  Option []  ["stop-unbox"](NoArg SStopUnbox)       "force+print unbox's output then stop (for testing)",
  Option []  ["stop-raw"](NoArg SStopRaw)           "force+print the raw, untransformed TProg then stop (for testing)",
  Option []  ["stop-optimize"](NoArg SStopOptimize) "force+print optimize's output then stop (for testing)"]
