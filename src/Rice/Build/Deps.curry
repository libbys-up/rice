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

import Rice.Build.Cache (readCachedImports, writeCachedImports)
import Rice.Frontend    (readModuleHeader)
import Rice.Diagnostics (timeIO)

--- Every module reachable from the root, mapped to its direct imports.
--- It holds only names, so building it doesn't have to parse every module.
type ModuleGraph = Map.Map String [String]

--- Finds every module reachable from `root` and each one's imports.
---
--- We read `root`'s header itself, because that's the only way to learn its
--- module name. For every other module we try the `.rimports` cache first
--- (`Rice.Build.Cache.readCachedImports`), and otherwise read the header of
--- its `.tfcy` (`Rice.Frontend.readModuleHeader`), which skips parsing the
--- rest.
buildModuleGraph :: Bool -> String -> IO ModuleGraph
buildModuleGraph timing root = do
  (rootName, rootImps) <- timeIO timing (root ++ ": readModuleHeader (root)")
                                  (readModuleHeader root)
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
      Nothing   -> timeIO timing (m ++ ": readModuleHeader (no .rimports cache)") $ do
        (_, imps) <- readModuleHeader m
        writeCachedImports m imps
        return imps

--- Sorts the module names so that a module's imports come before it.
--- `Left` names the modules in an import cycle, which Curry doesn't allow.
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
