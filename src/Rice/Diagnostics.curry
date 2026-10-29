------------------------------------------------------------------------------
--- Timing compiler stages, for `--compiler-time`. When the `Bool` flag is
--- `False`, each function just runs the action or returns the value.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Diagnostics ( timeIO, timePure, reportTime ) where

import System.CPUTime (getCPUTime)

--- Prints one timing line. KiCS2's `getCPUTime` reports milliseconds.
reportTime :: String -> Int -> IO ()
reportTime label ms = putStrLn ("TIME " ++ label ++ ": " ++ show ms ++ "ms")

--- Times an IO action. This only measures what the action forces while it
--- runs: if it returns a lazy value, the cost shows up in whichever later
--- stage forces it.
timeIO :: Bool -> String -> IO a -> IO a
timeIO on label act
  | not on    = act
  | otherwise = do
      t0 <- getCPUTime
      r  <- act
      t1 <- getCPUTime
      reportTime label (t1 - t0)
      return r

--- Times forcing a pure value to normal form, which we do by `show`ing it.
--- When the flag is off, `x` isn't forced at all.
timePure :: Show a => Bool -> String -> a -> IO a
timePure on label x
  | not on    = return x
  | otherwise = do
      t0 <- getCPUTime
      let forced = length (show x)
      t1 <- forced `seq` getCPUTime
      reportTime label (t1 - t0)
      return x
