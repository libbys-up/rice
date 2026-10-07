------------------------------------------------------------------------------
--- Save optimized files in their own format so we don't need to re-optimize them.
--- The cache file for a module lives right next to where kics2/pakcs
--- would put that module's own `.tfcy`
--- This mirrors FlatCurry.Typed.Files typedFlatCurryFileName
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
import System.CurryPath  (lookupModuleSourceInLoadPath, inCurrySubdir, modNameToPath)
import System.Directory  (doesFileExist, getModificationTime, createDirectoryIfMissing)
import System.FilePath   ((</>), (<.>), takeDirectory)
import FlatCurry.Types       (Prog)
import FlatCurry.Typed.Types (TProg)

--- Extension for optimized TypedFlatCurry
--- distinct from `.tfcy`
riceExt :: String
riceExt = "rtfcy"

--- Extension for the post-ANF, untyped FlatCurry `Prog` (`Rice.Main`'s
--- `fcy`: `removeTypes . normalize` applied to the optimized TProg above)
--- -- caching this avoids re-running ANF normalization (expensive: it
--- walks the whole program) and regenerating ICurry/.c/.h just because a
--- module's optimized-TProg cache was reused unchanged. Kept in lockstep
--- with `riceExt` -- this exists iff a stale-free `.rtfcy` implies it's
--- still valid, so `Rice.Main` only ever reads it when its own
--- `needsRecompile` check says the `.rtfcy` didn't need regenerating.
riceFcyExt :: String
riceFcyExt = "rfcy"

--- Extension for a module's cached *import list only* -- a tiny file
--- (a handful of module names) deliberately kept separate from the full
--- `.tfcy`/`.rtfcy`/`.rfcy` representations. `KiCS2`'s derived `Read`
--- instance for `TProg` turns out not to be incremental: forcing even a
--- single small field (confirmed directly -- forcing just `tProgImports`
--- on Prelude, which is `[]`, costs the same ~4s as forcing the whole
--- thing) reparses the entire `.tfcy` text, which for Prelude is ~2MB.
--- Since graph-building (`Rice.Build.Deps.buildModuleGraph`) and
--- topological sorting only ever need a module's *name and imports*,
--- not its full `TProg`, caching just that tiny fact here lets both of
--- those skip forcing the full `TProg` entirely for any module that
--- doesn't turn out to need actual reoptimization.
riceImportsExt :: String
riceImportsExt = "rimports"

--- Rice's directory for saving intermediate curry files.
--- This matches the standard curry convection of
--- .curry/compiler-version
riceSubdir :: String
riceSubdir = ".curry" </> "rice-1.0.0"

--- Get the full path to 
---  1. the module's source file.
---  2. the module's intermediate file (without any extensions)
--- all files including the .rtfcy, .c, and .h files will live here.
---
--- If we don't find the file, then error.
moduleBase :: String -> IO (FilePath, FilePath)
moduleBase m = do
  mbsrc <- lookupModuleSourceInLoadPath m
  let (dir, _) = fromMaybe (error notFound) mbsrc
  return (dir, dir </> riceSubdir </> modNameToPath m)
 where notFound = "Rice.Build.Cache: can't resolve module " ++ m

--- Get both the origonal .tfcy file, our our .rtfcy file
--- so we can check if we need to re-optimize.
modulePaths :: String -> IO (FilePath, FilePath)
modulePaths m = do
  (dir, riceBase) <- moduleBase m
  let tfcyBase = inCurrySubdir (dir </> m)
  return (tfcyBase <.> "tfcy", riceBase <.> riceExt)

--- The path to the .c and .h files.
--- They're in the same directory as everything else.
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

--- Does module m need to be re-optimized?
--- re-optimize if
---  1. There's no .rtfcy file.
---  2. The current .rtfcy file is older than the .tfcy file.
---  3. The current .rtfcy file is only than in imports .rtfcy file.
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

--- Write `new` to `path` if it doesn't exist or differs from what's
--- already there. If it's exactly the same, there's no point rewriting
--- it with itself and bumping its modification time -- for
--- `writeOptIfChanged`/`writeFcyIfChanged` below that would needlessly
--- force everything that imports this module to re-run; for any other
--- generated file (e.g. `Rice.Main`'s object-file cache) it would
--- needlessly invalidate whatever's keyed off that file's mtime.
writeFileIfChanged :: FilePath -> String -> IO ()
writeFileIfChanged path new = do
  exists <- doesFileExist path
  old <- case exists of
    False -> return Nothing
    True  -> do s <- readFile path
                -- readFile is lasy, but we want the entire file in memory
                -- so we can close it.
                -- length will force the entire file.
                -- I'm pretty sure we can just use normalForm here.
                --normalForm s $! return (Just s)
                length s `seq` return (Just s)
  -- I could combine this with the definition of old in a if/then/else,
  -- but I'm not sure if that will actually evaluate.  It will probably
  -- just return a giant cond thunk.
  case old of
    Just o | o == new -> return ()
    _ -> do createDirectoryIfMissing True (takeDirectory path)
            writeFile path new

--- Write the optimization file if either
---  1. it doesn't exists
---  2. it exists and is different from the cached version we have.
--- If it's exactly the same, then there's not point rewriting it with itself.
--- and forcing everything that imports us to re-run.
writeOptIfChanged :: String -> TProg -> IO ()
writeOptIfChanged m prog = do
  (_, opt) <- modulePaths m
  writeFileIfChanged opt (show prog)

--- Read a module's cached post-ANF, untyped FlatCurry `Prog`.
readCachedFcy :: String -> IO Prog
readCachedFcy m = do
  path <- fcyPath m
  read <$> readFile path

--- Write the `.rfcy` cache if it doesn't exist or differs from what's
--- there -- same rationale as `writeOptIfChanged`.
writeFcyIfChanged :: String -> Prog -> IO ()
writeFcyIfChanged m prog = do
  path <- fcyPath m
  writeFileIfChanged path (show prog)

--- A module's cached import list, but only when it's still trustworthy:
--- the `.rimports` file exists and is at least as new as the module's
--- own `.tfcy` (i.e. the source hasn't been reparsed by the frontend
--- since we last recorded its imports). `Nothing` on any cache miss --
--- the caller must fall back to a real parse, but that's exactly the
--- situation (a changed `.tfcy`) where a real parse was overwhelmingly
--- likely to be needed anyway, since it also means `needsRecompile`
--- will almost certainly say this module is stale.
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
