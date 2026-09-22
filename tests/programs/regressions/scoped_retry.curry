-- Exercises the generalized scoped-backtracking retry (opt #3): isGreen's
-- pattern match is incomplete (only Green), so evaluating isGreen pick
-- should locally retry through pick's choice points (Red, then Green)
-- rather than propagating the Red failure all the way to main as its own
-- separate top-level solution. Expected: the Red failure is absorbed
-- locally, and the separate Blue failure -- only discoverable by main's
-- own top-level retry after already returning True -- is silently
-- absorbed too, exactly like Red: nf_all only ever prints a line when
-- the final value isn't FAIL, so no failed attempt, local or top-level,
-- should ever produce its own "SOLUTION: FAIL" line. (An earlier version
-- of this comment expected Blue to print "SOLUTION: FAIL" -- that was
-- itself a symptom of a real bug in nf/ground_nf, since fixed: see
-- runtime/runtime.c's FAIL_TAG check right after each FORWARD_TAG chase.)
data Color = Red | Green | Blue

pick :: Color
pick = Red ? Green ? Blue

isGreen :: Color -> Bool
isGreen Green = True

main :: Bool
main = isGreen pick
