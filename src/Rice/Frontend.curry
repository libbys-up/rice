------------------------------------------------------------------------------
--- Finding modules and running the Curry front end, without depending on
--- the Curry system rice was built with.
---
--- Programs are compiled against rice's own standard library,
--- `$RICEHOME/lib` (a copy of KiCS2's, see `tools/sync-lib.sh`), with the
--- CPP symbol `__RICE__` defined. The front end writes its `.tfcy` files
--- into `.curry/rice-<version>/` beside each module's source, the same
--- directory as rice's own cache files (`Rice.Build.Cache`).
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Frontend ( riceHome, riceSubdir, lookupModule, tfcyPath,
                       readModule, readModuleFile, readModuleHeader ) where

import Control.Monad      (filterM, when)
import Data.Char          (isSpace)
import Data.List          (intercalate)
import System.Environment (getEnv)
import System.Directory   (doesFileExist)
import System.FilePath    ((</>), (<.>), takeDirectory, takeBaseName, takeExtension,
                           splitSearchPath)
import System.Process     (system, exitWith)
import System.CurryPath   (lookupModuleSource, modNameToPath)
import Curry.Compiler.Distribution (installDir, curryCompiler)
import FlatCurry.Typed.Types (TProg)
import ReadShowTerm          (readUnqualifiedTerm)

import Rice.PackageConfig (getPackagePath, packageVersion)

--- Where rice's `lib/`, `replace/` and `runtime/` are: `$RICEHOME` if it's
--- set. Otherwise, for a rice built by rice, its install directory (the
--- home of the rice that compiled it, or where it was built from the seed
--- C); for a rice built by cypm, the package directory it was installed
--- from. (Under rice, `getPackagePath` is wherever cypm generated
--- `Rice.PackageConfig`, which for the seed is another machine.)
riceHome :: IO FilePath
riceHome = do
  home <- getEnv "RICEHOME"
  if not (null home) then return home
    else if curryCompiler == "rice" then return installDir
    else getPackagePath

--- The directory, under each module's source directory, that holds the
--- front end's output and rice's cache files for that module.
riceSubdir :: FilePath
riceSubdir = ".curry" </> ("rice-" ++ packageVersion)

--- Where modules are looked for: the current directory, then `$CURRYPATH`,
--- then rice's standard library.
loadPath :: IO [FilePath]
loadPath = do
  home      <- riceHome
  currypath <- getEnv "CURRYPATH"
  return (["."] ++ filter (not . null) (splitSearchPath currypath)
                ++ [home </> "lib"])

--- The directory a module's source is in (the top of the hierarchy, for a
--- hierarchical module name), or `Nothing` if it isn't in the load path.
lookupModule :: String -> IO (Maybe FilePath)
lookupModule m = do
  path <- loadPath
  fmap (fmap fst) (lookupModuleSource path m)

--- The `.tfcy` the front end writes for module `m` whose source is in `dir`.
tfcyPath :: FilePath -> String -> FilePath
tfcyPath dir m = dir </> riceSubdir </> modNameToPath m <.> "tfcy"

--- Runs the front end on module `m`, found in the load path, and reads its
--- typed FlatCurry. The front end also brings the `.tfcy` of every module
--- `m` imports up to date. A file name (`Main.curry`, `dir/Main`) works
--- too: its directory is searched first, and the module name is the file's
--- base name.
readModule :: String -> IO TProg
readModule m = moduleTfcy m >>= readTfcy

--- Like `readModule`, for a module given by its file name (the module
--- name is the file's base name). Its directory is searched first.
readModuleFile :: FilePath -> IO TProg
readModuleFile file = fileTfcy file >>= readTfcy

--- Runs the front end on module `m` like `readModule`, but reads only the
--- module's name and imports, the first two fields of its `.tfcy`, without
--- parsing the rest. Building the module graph needs nothing else, and a
--- full parse of Prelude's takes seconds (`Rice.Build.Deps`).
readModuleHeader :: String -> IO (String, [String])
readModuleHeader m = do
  path <- moduleTfcy m
  s <- readFile path
  case scanHeader s of
    Just header -> return header
    Nothing     -> error ("Rice.Frontend: can't read the module name and "
                          ++ "imports at the start of " ++ path)

--- Runs the front end on module `m` (a module name, or a file name), and
--- returns the path of its `.tfcy`.
moduleTfcy :: String -> IO FilePath
moduleTfcy m
  | takeExtension m `elem` [".curry", ".lcurry"] || takeDirectory m /= "."
  = fileTfcy m
  | otherwise = do
  mbdir <- lookupModule m
  case mbdir of
    Nothing  -> do path <- loadPath
                   error ("Module " ++ m ++ " not found in the load path: "
                          ++ intercalate ":" path)
    Just dir -> runFrontend [dir] m >> return (tfcyPath dir m)

--- `moduleTfcy` for a file name.
fileTfcy :: FilePath -> IO FilePath
fileTfcy file = do
  let dir = takeDirectory file
      m   = takeBaseName file
  runFrontend [dir] m
  return (tfcyPath dir m)

--- Parses a `.tfcy`. Under KiCS2, `ReadShowTerm`'s reader is native code,
--- and takes a third of the time and a fifth of the memory of derived
--- `read`. Rice doesn't implement `ReadShowTerm` yet, so a rice-built rice
--- uses `read`.
readTfcy :: FilePath -> IO TProg
readTfcy path = do
  s <- readFile path
  return $ if curryCompiler == "kics2"
             then readUnqualifiedTerm ["FlatCurry.Typed.Types",
                                       "FlatCurry.Types", "Prelude"] s
             else read s

--- The module name and imports at the start of a `.tfcy`:
--- `TProg "M" ["A","B"] ...`. Module names have no quotes or escapes.
scanHeader :: String -> Maybe (String, [String])
scanHeader s = do
  r1 <- keyword "TProg" s
  (name, r2) <- stringLit r1
  r3 <- symbol '[' r2
  (imps, _) <- strings r3
  return (name, imps)
 where
  skip = dropWhile isSpace
  keyword k t = let t' = skip t
                in if take (length k) t' == k then Just (drop (length k) t')
                                              else Nothing
  symbol c t = case skip t of
                 (c':t') | c == c' -> Just t'
                 _                 -> Nothing
  stringLit t = case skip t of
                  ('"':t') -> let (str, rest) = break (== '"') t'
                              in Just (str, drop 1 rest)
                  _        -> Nothing
  -- after the '[': `"A","B"]` or `]`
  strings t = case skip t of
                (']':t') -> Just ([], t')
                _        -> do (str, t1) <- stringLit t
                               case skip t1 of
                                 (',':t2) -> do (strs, t3) <- strings t2
                                                return (str : strs, t3)
                                 (']':t2) -> Just ([str], t2)
                                 _        -> Nothing

--- Calls the front end on module `m`, with `dirs` ahead of the load path.
runFrontend :: [FilePath] -> String -> IO ()
runFrontend dirs m = do
  fe   <- frontend
  path <- loadPath
  -- -Odesugar-newtypes: ICurry generation would otherwise remove the
  -- newtypes itself, by inferring types again on the program after unbox
  -- and replace have changed it, and that fails.
  let cmd = unwords $ [quote fe, "--typed-flat", "--no-verb", "--no-warn",
                       "--no-overlap-warn", "-Odesugar-newtypes",
                       "-o", quote riceSubdir,
                       "-D__RICE__=" ++ show riceVersionNumber]
                      ++ map (("-i" ++) . quote) (dirs ++ path)
                      ++ [quote m]
  code <- system cmd
  -- The front end has already printed what went wrong.
  when (code /= 0) (exitWith 1)
 where
  quote s = "\"" ++ s ++ "\""

--- `__RICE__`'s value: the major version times 100 plus the minor version,
--- as the other Curry systems do.
riceVersionNumber :: Int
riceVersionNumber = case map read (splitOn '.' packageVersion) of
  (major : minor : _) -> major * 100 + minor
  _                   -> 0
 where
  splitOn c s = case break (== c) s of
    (w, [])       -> [w]
    (w, _ : rest) -> w : splitOn c rest

--- The front end executable: `$RICE_FRONTEND` if it's set; otherwise
--- `bin/curry-frontend` under `riceHome`, which `make frontend` builds from
--- the pinned `frontend/` submodule; otherwise the front end of the Curry
--- system rice was built with; otherwise the first of `curry-frontend`,
--- `kics2-frontend` and `pakcs-frontend` on `$PATH`.
frontend :: IO FilePath
frontend = do
  env <- getEnv "RICE_FRONTEND"
  if not (null env) then return env else do
    home     <- riceHome
    pathDirs <- fmap splitSearchPath (getEnv "PATH")
    let ours       = home </> "bin" </> "curry-frontend"
        builtWith  = installDir </> "bin" </> (curryCompiler ++ "-frontend")
        candidates = ours : builtWith : [ d </> f | f <- [ "curry-frontend"
                                                  , "kics2-frontend"
                                                  , "pakcs-frontend" ]
                                           , d <- pathDirs ]
    found <- filterM doesFileExist candidates
    case found of
      (fe : _) -> return fe
      []       -> error ("No Curry front end found. Run `make frontend` in "
                         ++ home ++ ", or set RICE_FRONTEND to a "
                         ++ "curry-frontend executable.")
