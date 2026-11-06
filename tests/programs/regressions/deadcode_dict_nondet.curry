-- Rice.Optimize.Inline.isIOType (deadCode's helper for deciding whether a
-- dropped Let's effect must still run) was written as two top-level
-- equations instead of a `case`:
--
--   isIOType (TCons ("Prelude", "IO") _) = True
--   isIOType _                           = False
--
-- KiCS2 can't prove these mutually exclusive (confirmed directly via its
-- own frontend warning: "Function `isIOType' is potentially
-- non-deterministic due to overlapping rules"), so it compiles this to a
-- genuinely nondeterministic dispatch. deadCode's `TLet` rule calls
-- isIOType on the type of *every* single-binding Let it considers
-- dropping -- including the extremely common case of REDUCE inlining a
-- call to a typeclass-constrained function and leaving behind an unused
-- dictionary argument (subGrounded always wraps a non-ground argument,
-- like a dictionary FuncPartCall, in its own Let). The resulting
-- nondeterminism gets silently baked into the optimized AST -- invisible
-- until something forces it strictly: Rice.Build.Cache.writeOptIfChanged
-- forcing `show prog` to write the .rtfcy cache fails outright with
-- "Non-determinism in IO occured", which resurfaces one layer up as
-- KiCS2's generic "List data with no ground term" once the broken lazy
-- string is bridged to a real Haskell String for writeFile.
--
-- This blocked essentially kics2's entire testsuite (any module
-- importing Test.Prop, whose `-=-`/`<~>`/etc. are small, dictionary-
-- constrained, unreachable-but-still-optimized functions) plus several
-- benchmarks, and doesn't need Test.Prop to reproduce -- any unreachable
-- call to a small (Eq/Show/...)-constrained function is enough, as here.
--
-- Fixed by rewriting isIOType with a `case`, matching the same fix
-- already applied elsewhere in this codebase for exactly this hazard
-- (see FlatCurry.Transform.Typed.Goodies's own note on it).
myUndef :: (Eq a, Show a) => a -> String
myUndef _ = "hello"

-- Never called from main -- optimizeProg still runs over every top-level
-- function regardless of reachability, so this alone was enough to
-- poison the whole module's .rtfcy write.
unreachable :: String
unreachable = myUndef (1 :: Int)

main :: IO ()
main = putStrLn "it works"
