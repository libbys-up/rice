-- rice-mode: interactive
--
-- Prelude__bindIO_hnf (runtime/ext/Prelude.c) didn't commit choices made
-- while settling its first argument: `m = settle(m, NULL, HNF_SETTLE)`
-- can dispatch a CHOICE_TAG node reached along the way (here, forcing
-- `1 ? 2` inside `print`), which pushes a real frame onto bt_stack via
-- choose() -- but the very next line, `apply_hnf(root)`, immediately
-- overwrites `root` in place with the rest of the do-block's result,
-- permanently orphaning that choice from the reachable graph. Nothing
-- ever points back at it again, so no actual re-execution happens, but
-- the leftover frame still sits on bt_stack. nf_all's own top-level
-- "try another solution" loop (`while(undo(0))`) later finds and
-- restores it anyway, re-running nf() on a graph that never changed,
-- and printing this program's harmless `()` result a second time even
-- though it only actually ran once. Fixed by having bindIO record
-- bt_stack's size before doing any work and `pop_to` (discard, not
-- restore) back down to it once its own full dispatch -- settling `m`
-- and running `f` via apply_hnf -- is done, so nothing pushed during
-- *this* bindIO call is ever visible to a later undo() again. This is
-- also the soundness bar a future `catch`'s cutoff-based design needs
-- bt_stack to actually meet.
--
-- Forced into --interactive mode (see tests/run.sh's `rice-mode`
-- override) since the symptom is specifically about nf_all's retry
-- loop -- Rice's default standalone-executable mode (run_io) never
-- attempts backtracking at the top level at all, so a plain `IO ()`
-- program wouldn't exercise this bug regardless of whether it was
-- fixed.
main :: IO ()
main = do
  putStrLn "before"
  print (1 ? 2 :: Int)
  putStrLn "after"
