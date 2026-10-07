------------------------------------------------------------------------------
--- Opt-in compiler-stage timing, shared by `Rice.Main` and `Rice.Build.Deps`.
--- Everything here is a no-op (just `return`/run the action untouched) when
--- its `Bool` flag is `False`, so leaving `--compiler-time` off costs nothing
--- beyond the extra branch.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Diagnostics ( timeIO, timePure, reportTime ) where

import System.CPUTime (getCPUTime)

--- Print one timing line. `getCPUTime` (System.CPUTime) already reports
--- milliseconds despite its name, not picoseconds -- earlier ad hoc
--- diagnostics in this codebase mislabeled it "ps".
reportTime :: String -> Int -> IO ()
reportTime label ms = putStrLn ("TIME " ++ label ++ ": " ++ show ms ++ "ms")

--- Time an IO action when the flag is on; otherwise run it untouched.
--- This only measures what the action itself forces while running --
--- if it returns a value whose construction is actually lazy (e.g. an
--- AST only demanded later, when it's printed or written to a file),
--- that later point is where the real cost will show up instead. That's
--- fine: it still tells you which stage is paying for the work, just not
--- always the stage that superficially produced the value.
timeIO :: Bool -> String -> IO a -> IO a
timeIO on label act
  | not on    = act
  | otherwise = do
      t0 <- getCPUTime
      r  <- act
      t1 <- getCPUTime
      reportTime label (t1 - t0)
      return r

--- Time forcing a pure, `Show`-able value to normal form when the flag is
--- on, via `show` (the same trick `Rice.Build.Cache` already relies on to
--- fully force a `TProg` before writing/comparing its `.rtfcy` cache).
--- When the flag is off this returns `x` completely unforced, so it's
--- safe to drop into any `let`-binding call site without changing
--- behavior.
timePure :: Show a => Bool -> String -> a -> IO a
timePure on label x
  | not on    = return x
  | otherwise = do
      t0 <- getCPUTime
      let forced = length (show x)
      t1 <- forced `seq` getCPUTime
      reportTime label (t1 - t0)
      return x
