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
                       readModule, readModuleFile ) where

import Control.Monad      (filterM, when)
import Data.List          (intercalate)
import System.Environment (getEnv)
import System.Directory   (doesFileExist)
import System.FilePath    ((</>), (<.>), takeDirectory, takeBaseName, takeExtension,
                           splitSearchPath)
import System.Process     (system, exitWith)
import System.CurryPath   (lookupModuleSource, modNameToPath)
import Curry.Compiler.Distribution (installDir, curryCompiler)
import FlatCurry.Typed.Types (TProg)
import FlatCurry.Typed.Files (readTypedFlatCurryFile)

import Rice.PackageConfig (getPackagePath, packageVersion)

--- Where rice's `lib/`, `replace/` and `runtime/` are: `$RICEHOME` if it's
--- set, otherwise the package directory rice was installed from.
riceHome :: IO FilePath
riceHome = do
  home <- getEnv "RICEHOME"
  if null home then getPackagePath else return home

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
--- `m` imports up to date. A file name (`Main.curry`, `dir/Main`) is read
--- with `readModuleFile`.
readModule :: String -> IO TProg
readModule m
  | takeExtension m `elem` [".curry", ".lcurry"] || takeDirectory m /= "."
  = readModuleFile m
  | otherwise = do
  mbdir <- lookupModule m
  case mbdir of
    Nothing  -> do path <- loadPath
                   error ("Module " ++ m ++ " not found in the load path: "
                          ++ intercalate ":" path)
    Just dir -> runFrontend [dir] m >> readTypedFlatCurryFile (tfcyPath dir m)

--- Like `readModule`, for a module given by its file name (the module
--- name is the file's base name). Its directory is searched first.
readModuleFile :: FilePath -> IO TProg
readModuleFile file = do
  let dir = takeDirectory file
      m   = takeBaseName file
  runFrontend [dir] m
  readTypedFlatCurryFile (tfcyPath dir m)

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
