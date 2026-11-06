-- Reduced from the original `fib 7` (2,097,152 solutions -- each of the
-- 21 base-case leaves in the naive, unmemoized recursion tree
-- independently picks 0 or 1 via `?`, so the solution count is
-- 2^(number of leaves), not fib itself) after its golden ballooned to
-- 25MB, a repo-bloat hazard rather than a cheap/contained cost like
-- this directory's other SLOW entries.
--
-- `fib 6` (8192 solutions, 13 leaves) keeps the same point -- unshared
-- `?` under recursion blows up combinatorially, independent of the
-- actual fib value -- at a 98KB golden and a sub-10ms run, measured
-- directly. That's fast enough to no longer need the SLOW tag at all
-- (dropped from manifest.txt); the original's "runs well past a 15s
-- timeout" was true of `fib 7` specifically, not of this test's point
-- in general.
fib :: Int -> Int
fib n
 | n < 2 = 0 ? 1
 | otherwise = fib (n-1) + fib (n-2)

main = fib 6
