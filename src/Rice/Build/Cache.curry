------------------------------------------------------------------------------
--- Rice's per-module cache files, and deciding when they're stale.
---
--- A module's files live in `.curry/rice-<version>/` next to its source,
--- with the front end's `.tfcy` (`Rice.Frontend`):
---   `.rtfcy`    the optimized typed FlatCurry
---   `.rfcy`     the untyped FlatCurry after ANF
---   `.rimports` the module's import list
---   `.h`, `.c`  the generated code (and `.o`, `.o.flags`, see `Rice.Main`)
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
                          readCachedImports,
                          writeCachedImports
 ) where

import Data.Maybe        (fromMaybe)
import System.CurryPath  (modNameToPath)
import System.Directory  (doesFileExist, getModificationTime, createDirectoryIfMissing)
import System.FilePath   ((</>), (<.>), takeDirectory)
import FlatCurry.Types       (Prog)
import FlatCurry.Typed.Types (TProg)

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

--- Does module `m` need to be compiled again? It does if
---  1. it has no `.rtfcy`,
---  2. its `.rtfcy` is older than its `.tfcy`, or
---  3. its `.rtfcy` is older than an import's `.rtfcy`.
--- The `.rtfcy` is only rewritten when it changes (`writeFileIfChanged`),
--- so a change only spreads to the modules it can affect.
needsRecompile :: String -> [String] -> IO Bool
needsRecompile m imports = do
  (tfcy, opt) <- modulePaths m
  exists <- doesFileExist opt
  case exists of
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

--- Read a module's cached optimized TypedFlatCurry.
readCachedOpt :: String -> IO TProg
readCachedOpt m = do
  (_, opt) <- modulePaths m
  read <$> readFile opt

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
    _ -> do createDirectoryIfMissing True (takeDirectory path)
            writeFile path new

--- Writes the module's `.rtfcy`, if it changed.
writeOptIfChanged :: String -> TProg -> IO ()
writeOptIfChanged m prog = do
  (_, opt) <- modulePaths m
  writeFileIfChanged opt (show prog)

--- Read a module's cached post-ANF, untyped FlatCurry `Prog`.
readCachedFcy :: String -> IO Prog
readCachedFcy m = do
  path <- fcyPath m
  read <$> readFile path

--- Writes the module's `.rfcy`, if it changed.
writeFcyIfChanged :: String -> Prog -> IO ()
writeFcyIfChanged m prog = do
  path <- fcyPath m
  writeFileIfChanged path (show prog)

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
