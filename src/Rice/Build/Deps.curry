------------------------------------------------------------------------------
--- The module dependency graph: reading a module and everything it
--- (transitively) imports, and putting the result in dependency order.
---
--- Module resolution (via CURRYPATH) and regenerating a module's
--- TypedFlatCurry when it's stale are already `readTypedFlatCurry`'s job
--- -- this module only walks the import graph it exposes.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Build.Deps
  ( ModuleGraph, buildModuleGraph, topoSort
 ) where

import qualified Data.Map as Map
import Data.SCC (scc)

import FlatCurry.Typed.Types   (TProg)
import FlatCurry.Typed.Goodies (tProgName, tProgImports)
import FlatCurry.Typed.Files   (readTypedFlatCurry)

--- Every module reachable from some root, keyed by name.
type ModuleGraph = Map.Map String TProg

--- Read a module and everything it (transitively) imports.
buildModuleGraph :: String -> IO ModuleGraph
buildModuleGraph root = go Map.empty [root]
 where
  go graph ms = case ms of
    []     -> return graph
    (m:ms')
      | Map.member m graph -> go graph ms'
      | otherwise           -> do
          prog <- readTypedFlatCurry m
          go (Map.insert m prog graph) (tProgImports prog ++ ms')

--- Sort a module graph into dependency order (a module's imports always
--- come before it). `Left` names a cyclic import -- Curry doesn't allow
--- those, so this is always a hard error to report, never something to
--- recover from.
topoSort :: ModuleGraph -> Either [String] [TProg]
topoSort graph =
  collect (scc (\p -> [tProgName p]) tProgImports (Map.elems graph))
 where
  collect grps = case grps of
    []         -> Right []
    (grp:grps') -> case grp of
      [p] | tProgName p `elem` tProgImports p -> Left [tProgName p]
          | otherwise -> case collect grps' of
                           Left cyc -> Left cyc
                           Right ps -> Right (p:ps)
      ps -> Left (map tProgName ps)

------------------------------------------------------------------------------
