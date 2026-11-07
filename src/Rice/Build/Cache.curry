------------------------------------------------------------------------------
--- Rice's per-module cache files, and deciding when they're stale.
---
--- A module's files live in `.curry/rice-<version>/` next to its source,
--- with the front end's `.tfcy` (`Rice.Frontend`):
---   `.rtfcy`    the typed FlatCurry after the optimizer (if it ran)
---   `.rmode`    whether the optimizer ran (`optimized` or `plain`)
---   `.rfcy`     the untyped FlatCurry after ANF
---   `.rimports` the module's import list
---   `.h`, `.c`  the generated code (and `.o`, `.o.flags`, see `Rice.Main`)
--- `.rtfcy` and `.rfcy` are in rw-data's compact format (`RW.Base`, with
--- the instances in `FlatCurry.TypesRW` and `Rice.Build.TypedRW`). Under
--- KiCS2, derived `read` of Prelude's `.rtfcy` as text took 6 s and 3.3 GB.
--- See the developer's manual, "Separate compilation and caching".
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Build.Cache ( needsRecompile,
                          readCachedOpt,
                          writeOptIfChanged,
                          cPaths,
                          fcyPath,
                          readCachedFcy,
                          writeFcyIfChanged,
                          writeFileIfChanged,
                          writeFileAtomic,
                          beginModule,
                          finishModule,
                          readCachedImports,
                          writeCachedImports
 ) where

import Data.Maybe        (fromMaybe)
import Control.Monad     (when)
import System.CurryPath  (modNameToPath)
import System.Directory  (doesFileExist, getModificationTime, createDirectoryIfMissing,
                          removeFile, renameFile)
import System.FilePath   ((</>), (<.>), takeDirectory)
import FlatCurry.Types       (Prog)
import FlatCurry.TypesRW     ()
import FlatCurry.Typed.Types (TProg)
import RW.Base               (ReadWrite, readData, showData)

import Rice.Build.TypedRW    ()

import Rice.Frontend (riceSubdir, lookupModule, tfcyPath)

--- The optimized typed FlatCurry.
riceExt :: String
riceExt = "rtfcy"

--- The untyped FlatCurry after ANF, which later modules' ICurry generation
--- needs. It's only valid when the `.rtfcy` is, so `Rice.Main` only reads
--- it for a module that isn't stale.
riceFcyExt :: String
riceFcyExt = "rfcy"

--- Just the module's imports. Reading any field of a `TProg` parses the
--- whole `.tfcy`, so `Rice.Build.Deps` reads this instead.
riceImportsExt :: String
riceImportsExt = "rimports"

--- Whether the `.rtfcy` was optimized. A module compiled the other way is
--- stale, so `--optimize` never picks up an unoptimized cache, or the
--- reverse. A cache from before this file existed is stale too.
riceModeExt :: String
riceModeExt = "rmode"

--- The contents of the `.rmode` file.
modeString :: Bool -> String
modeString optimize = if optimize then "optimized\n" else "plain\n"

--- The directory holding the module's source, and the path of its Rice
--- files without an extension. It's an error if we can't find the module.
moduleBase :: String -> IO (FilePath, FilePath)
moduleBase m = do
  mbdir <- lookupModule m
  let dir = fromMaybe (error notFound) mbdir
  return (dir, dir </> riceSubdir </> modNameToPath m)
 where notFound = "Rice.Build.Cache: can't resolve module " ++ m

--- The module's `.tfcy` (from the front end) and its `.rtfcy`.
modulePaths :: String -> IO (FilePath, FilePath)
modulePaths m = do
  (dir, riceBase) <- moduleBase m
  return (tfcyPath dir m, riceBase <.> riceExt)

--- The module's `.c` and `.h`.
cPaths :: String -> IO (FilePath, FilePath)
cPaths m = do
  (_, base) <- moduleBase m
  return (base <.> "c", base <.> "h")

--- The path to the cached post-ANF, untyped FlatCurry `.rfcy` file.
fcyPath :: String -> IO FilePath
fcyPath m = do
  (_, base) <- moduleBase m
  return (base <.> riceFcyExt)

--- The path to the cached `.rimports` file.
importsPath :: String -> IO FilePath
importsPath m = do
  (_, base) <- moduleBase m
  return (base <.> riceImportsExt)

--- Does module `m` need to be compiled again? `optimize` says whether this
--- compile runs the optimizer. It does if
---  0. its `.rmode` is missing, or says it was compiled the other way,
---  1. it has no `.rtfcy`,
---  2. its `.rtfcy` is older than its `.tfcy`, or
---  3. its `.rtfcy` is older than an import's `.rtfcy`.
--- The `.rtfcy` is only rewritten when it changes (`writeFileIfChanged`),
--- so a change only spreads to the modules it can affect.
needsRecompile :: Bool -> String -> [String] -> IO Bool
needsRecompile optimize m imports = do
  (tfcy, opt) <- modulePaths m
  sameMode <- modeMatches optimize m
  exists <- doesFileExist opt
  case sameMode && exists of
    False -> return True
    True  -> do
      optTime  <- getModificationTime opt
      tfcyTime <- getModificationTime tfcy
      impStale <- mapM (isNewerThanOpt optTime) imports
      return (tfcyTime > optTime || or impStale)
 where
  isNewerThanOpt optTime i = do
    (_, iopt) <- modulePaths i
    iexists <- doesFileExist iopt
    case iexists of
      False -> return True
      True  -> fmap (> optTime) (getModificationTime iopt)

--- Does the module's `.rmode` say it was compiled with `optimize`?
modeMatches :: Bool -> String -> IO Bool
modeMatches optimize m = do
  path <- modePath m
  exists <- doesFileExist path
  case exists of
    False -> return False
    True  -> do s <- readFile path
                return (s == modeString optimize)

modePath :: String -> IO FilePath
modePath m = do
  (_, base) <- moduleBase m
  return (base <.> riceModeExt)

--- Read a module's cached TypedFlatCurry (after the optimizer, if it ran).
readCachedOpt :: String -> IO TProg
readCachedOpt m = do
  (_, opt) <- modulePaths m
  readCompact opt

--- Reads a file in rw-data's compact format.
readCompact :: ReadWrite a => FilePath -> IO a
readCompact path = do
  s <- readFile path
  case readData s of
    Just x  -> return x
    Nothing -> error ("Rice.Build.Cache: can't read " ++ path
                      ++ "; delete it and compile again")

--- Writes `new` to `path`, unless the file already holds exactly that.
--- Leaving an unchanged file alone keeps its modification time, which is
--- what every staleness check here is based on.
writeFileIfChanged :: FilePath -> String -> IO ()
writeFileIfChanged path new = do
  exists <- doesFileExist path
  old <- case exists of
    False -> return Nothing
    True  -> do s <- readFile path
                -- readFile is lazy. Forcing the whole string closes the
                -- file before we might write to it.
                length s `seq` return (Just s)
  case old of
    Just o | o == new -> return ()
    _ -> writeFileAtomic path new

--- Writes `new` to `path` through a temporary file that's then renamed,
--- so `path` never holds half a file, even if rice is interrupted while
--- writing it.
writeFileAtomic :: FilePath -> String -> IO ()
writeFileAtomic path new = do
  createDirectoryIfMissing True (takeDirectory path)
  let tmp = path ++ ".tmp"
  writeFile tmp new
  renameFile tmp path

--- Called before compiling module `m`: removes its `.rmode`, so if this
--- compile is interrupted, the module counts as stale next time, whatever
--- its other cache files hold.
beginModule :: String -> IO ()
beginModule m = do
  path <- modePath m
  exists <- doesFileExist path
  when exists (removeFile path)

--- Called once every cache file of module `m` is written: records how it
--- was compiled (`optimize`), which makes the cache valid.
finishModule :: Bool -> String -> IO ()
finishModule optimize m = do
  path <- modePath m
  writeFileIfChanged path (modeString optimize)

--- Writes the module's `.rtfcy`, if it changed. (`finishModule` writes its
--- `.rmode`, once the rest of the module is written too.)
writeOptIfChanged :: String -> TProg -> IO ()
writeOptIfChanged m prog = do
  (_, opt) <- modulePaths m
  writeFileIfChanged opt (showData prog)

--- Read a module's cached post-ANF, untyped FlatCurry `Prog`.
readCachedFcy :: String -> IO Prog
readCachedFcy m = do
  path <- fcyPath m
  readCompact path

--- Writes the module's `.rfcy`, if it changed.
writeFcyIfChanged :: String -> Prog -> IO ()
writeFcyIfChanged m prog = do
  path <- fcyPath m
  writeFileIfChanged path (showData prog)

--- A module's cached imports, if its `.rimports` is at least as new as
--- its `.tfcy`. `Nothing` means the caller has to parse the module.
readCachedImports :: String -> IO (Maybe [String])
readCachedImports m = do
  (tfcy, _) <- modulePaths m
  ipath <- importsPath m
  iexists <- doesFileExist ipath
  if not iexists then return Nothing else do
    texists <- doesFileExist tfcy
    if not texists then return Nothing else do
      iTime <- getModificationTime ipath
      tTime <- getModificationTime tfcy
      if tTime > iTime then return Nothing
                        else Just . read <$> readFile ipath

--- Record a module's import list for `readCachedImports` above.
writeCachedImports :: String -> [String] -> IO ()
writeCachedImports m imports = do
  ipath <- importsPath m
  writeFileIfChanged ipath (show imports)

------------------------------------------------------------------------------
