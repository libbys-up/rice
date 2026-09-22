-- Exercises the generalized scoped-backtracking retry (opt #3): isGreen's
-- pattern match is incomplete (only Green), so evaluating isGreen pick
-- should locally retry through pick's choice points (Red, then Green)
-- rather than propagating the Red failure all the way to main as its own
-- separate top-level solution. Expected: the Red failure is absorbed
-- locally (never becomes its own "SOLUTION: FAIL" line) and only the
-- genuinely separate Blue failure -- only discoverable by main's own
-- top-level retry after already returning True -- still shows up.
data Color = Red | Green | Blue

pick :: Color
pick = Red ? Green ? Blue

isGreen :: Color -> Bool
isGreen Green = True

main :: Bool
main = isGreen pick
