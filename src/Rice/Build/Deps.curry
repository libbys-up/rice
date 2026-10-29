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

--- Every module reachable from the root, mapped to its direct imports.
--- It holds only names, so building it doesn't have to parse every module.
type ModuleGraph = Map.Map String [String]

--- Finds every module reachable from `root` and each one's imports.
---
--- We parse `root` itself, because that's the only way to learn its module
--- name. For every other module we try the `.rimports` cache first
--- (`Rice.Build.Cache.readCachedImports`), because reading any part of a
--- `TProg` parses the whole `.tfcy`, which takes seconds for Prelude. We
--- only parse a module when its `.tfcy` has changed, and then it's almost
--- always stale and has to be recompiled anyway.
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
