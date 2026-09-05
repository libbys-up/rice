------------------------------------------------------------------------------
--- Staleness checking and persistence for Rice's own per-module output:
--- the optimized TypedFlatCurry `Rice.Optimize.Inline.optimizeProg`
--- produces, cached across runs the same way kics2/pakcs/curry2go each
--- cache their own compiler-specific intermediate files.
---
--- The cache file for a module lives right next to where kics2/pakcs
--- would put that module's own `.tfcy` (`inCurrySubdir`'s convention,
--- e.g. next to Prelude.curry itself for library modules) so it survives
--- exactly as long as -- and moves with -- everything else already
--- cached for that module. This mirrors `FlatCurry.Typed.Files`' own
--- (unexported) `typedFlatCurryFileName` computation, since there's no
--- public way to just ask it for that path.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Build.Cache
  ( needsRecompile, readCachedOpt, writeOptIfChanged, cPaths
 ) where

import Data.Maybe        ( fromMaybe )
import System.CurryPath  ( lookupModuleSourceInLoadPath, inCurrySubdir
                          , modNameToPath )
import System.Directory  ( doesFileExist, getModificationTime
                          , createDirectoryIfMissing )
import System.FilePath   ( (</>), (<.>), takeDirectory )

import FlatCurry.Typed.Types (TProg)

--- Extension for Rice's own cached, optimized TypedFlatCurry -- distinct
--- from `.tfcy` (that's the frontend's, not ours).
riceExt :: String
riceExt = "rtfcy"

--- Rice's own compiler-and-version-namespaced subdirectory, matching the
--- `.curry/<compiler>-<version>/` convention kics2/pakcs/curry2go each
--- use for their own cache -- deliberately *not* `System.CurryPath.
--- currySubdir`, which reports whichever compiler is actually running
--- (kics2, here, since that's what Rice itself is built with) rather
--- than Rice's own identity; using it directly would silently dump
--- Rice's cache into kics2's own cache directory.
riceSubdir :: String
riceSubdir = ".curry" </> "rice-1.0.0"

--- The directory a module's source lives in, and Rice's own
--- compiler-namespaced base path within it (`<dir>/.curry/rice-1.0.0/
--- <ModPath>`, no extension yet) -- shared by every path computation
--- below. Errors if the module can't be resolved at all -- shouldn't
--- happen for anything `readTypedFlatCurry` (called earlier, while
--- building the module graph) already succeeded on.
moduleBase :: String -> IO (FilePath, FilePath)
moduleBase m = do
  mbsrc <- lookupModuleSourceInLoadPath m
  let (dir, _) = fromMaybe (error notFound) mbsrc
  return (dir, dir </> riceSubdir </> modNameToPath m)
 where notFound = "Rice.Build.Cache: can't resolve module " ++ m

--- A module's own generated `.tfcy` path (so its freshness can be
--- checked), and the path of Rice's own cached optimized artifact for it.
modulePaths :: String -> IO (FilePath, FilePath)
modulePaths m = do
  (dir, riceBase) <- moduleBase m
  -- Mirrors FlatCurry.Typed.Files' own (unexported) computation of
  -- a module's .tfcy path -- there's no public way to just ask it.
  let tfcyBase = inCurrySubdir (dir </> m)
  return (tfcyBase <.> "tfcy", riceBase <.> riceExt)

--- Where a module's generated `.c`/`.h` (`Rice.Codegen.C.{ToC,ToH}`)
--- should be written -- same directory and namespacing as the optimized-
--- TProg cache above, just a different extension, so generated C output
--- moves and ages with everything else already cached for that module.
cPaths :: String -> IO (FilePath, FilePath)
cPaths m = do
  (_, base) <- moduleBase m
  return (base <.> "c", base <.> "h")

--- Does module `m`'s cached optimized artifact need regenerating? True
--- if it's missing, older than the module's own (already-current, per
--- `readTypedFlatCurry`'s own freshness check) `.tfcy`, or older than
--- any import's own cached artifact.
---
--- That last check is the same transitive-staleness trick as kics2's
--- `CurryBuilder.smake`: an import's cache mtime only actually advances
--- when its content changed (see `writeOptIfChanged`), so comparing
--- against just the immediate imports here is enough to propagate
--- staleness through the whole dependency chain, without needing to
--- walk it explicitly.
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

--- Read a module's cached optimized TypedFlatCurry. Only sensible to
--- call after `needsRecompile` said `False`.
readCachedOpt :: String -> IO TProg
readCachedOpt m = do
  (_, opt) <- modulePaths m
  s <- readFile opt
  return (read s)

--- Persist a module's optimized TypedFlatCurry, but only actually write
--- (and so only actually bump the cache file's mtime) if it differs from
--- what's already there -- mirrors kics2's own `matchInterface` trick:
--- recompiling a module whose optimizer output didn't change shouldn't
--- cascade a rebuild to everything that imports it.
writeOptIfChanged :: String -> TProg -> IO ()
writeOptIfChanged m prog = do
  (_, opt) <- modulePaths m
  let new = show prog
  exists <- doesFileExist opt
  -- `readFile` is lazy, and `==` below short-circuits at the first
  -- difference -- without forcing the whole string here first, a
  -- changed file leaves its read handle still open (never hit EOF) when
  -- the `writeFile` a few lines down immediately tries to open the same
  -- path, which fails ("resource busy (file is locked)"). `length`
  -- forces full consumption, draining the handle to EOF so it closes.
  old <- case exists of
    False -> return Nothing
    True  -> do s <- readFile opt
                length s `seq` return (Just s)
  case old of
    Just o | o == new -> return ()
    _ -> do createDirectoryIfMissing True (takeDirectory opt)
            writeFile opt new

------------------------------------------------------------------------------
