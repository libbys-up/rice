------------------------------------------------------------------------------
--- The module dependency graph: reading a module and everything it imports,
--- and putting the result in dependency order.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Build.Deps
  ( ModuleGraph, buildModuleGraph, topoSort
 ) where

import qualified Data.Map as Map
import Data.SCC (scc)

import FlatCurry.Typed.Goodies (tProgName, tProgImports)
import FlatCurry.Typed.Files   (readTypedFlatCurry)

import Rice.Build.Cache (readCachedImports, writeCachedImports)
import Rice.Diagnostics (timeIO)

--- Every module reachable from some root, keyed by name, mapped to its
--- own (direct) imports -- deliberately not the full `TProg`. See
--- `buildModuleGraph`.
type ModuleGraph = Map.Map String [String]

--- Discover every module reachable from `root` and each one's direct
--- imports, without ever forcing a full `TProg` for a module we don't
--- otherwise need one for. `root` (the file given on the command line)
--- is parsed for real -- there's no cheaper way to learn its true module
--- name, and as ordinary user code it's normally small, so this is fine.
--- Every module reachable from there, though, is referenced by its real
--- name (straight from some other module's own `tProgImports`), so for
--- those `Rice.Build.Cache.readCachedImports` is tried first: a tiny
--- side-cache of just the import list, valid exactly when the module's
--- `.tfcy` hasn't changed since it was last recorded. Only on a cache
--- miss (missing, or the `.tfcy` changed since) do we fall back to
--- `readTypedFlatCurry` and force `tProgImports` on the result -- which,
--- for a module the size of Prelude, is where "reading Prelude takes
--- ~4s" actually comes from (KiCS2's derived `Read TProg` instance
--- isn't incremental: forcing any one field reparses the whole ~2MB
--- `.tfcy`, confirmed by timing `tProgImports` alone). That fallback
--- case is also, not coincidentally, almost always exactly the case
--- where the module turns out to be stale and needs a real recompile
--- anyway (see `Rice.Build.Cache.needsRecompile`), so the cost isn't
--- wasted even when it's paid.
buildModuleGraph :: Bool -> String -> IO ModuleGraph
buildModuleGraph timing root = do
  rootProg <- timeIO timing (root ++ ": readTypedFlatCurry (root)") (readTypedFlatCurry root)
  let rootName = tProgName rootProg
      rootImps = tProgImports rootProg
  writeCachedImports rootName rootImps
  go (Map.singleton rootName rootImps) rootImps
 where
  go graph ms = case ms of
     []     -> return graph
     (m:ms')
      | Map.member m graph -> go graph ms'
      | otherwise          -> do
          imps <- importsFor m
          go (Map.insert m imps graph) (imps ++ ms')

  importsFor m = do
    cached <- readCachedImports m
    case cached of
      Just imps -> return imps
      Nothing   -> timeIO timing (m ++ ": full parse for imports (no .rimports cache)") $ do
        prog <- readTypedFlatCurry m
        let imps = tProgImports prog
        writeCachedImports m imps
        return imps

--- Sort a module graph into dependency order (a module's imports always
--- come before it), returning module names -- `Rice.Main` fetches each
--- one's actual `TProg` itself, only once it knows whether that module
--- is actually stale. `Left` names a cyclic import -- Curry doesn't
--- allow those, so this is always a hard error to report, never
--- something to recover from.
topoSort :: ModuleGraph -> Either [String] [String]
topoSort graph =
  collect (scc (\(name,_) -> [name]) snd (Map.toList graph))
 where
  collect grps = case grps of
    []         -> Right []
    (grp:grps') -> case grp of
      [(name,imps)] | name `elem` imps -> Left [name]
                    | otherwise -> case collect grps' of
                                     Left cyc -> Left cyc
                                     Right ns -> Right (name:ns)
      ps -> Left (map fst ps)

------------------------------------------------------------------------------
