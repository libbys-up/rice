
-- Reduced from the original [1..9] (362880 permutations, no pruning --
-- the whole point is enumerating every one via nf_all, not stopping at
-- the first solution) after it was measured actually consuming ~115GB
-- of RAM and had to be killed mid-run -- a real hazard to the host
-- machine, not just a slow/XSLOW test worth tolerating (unlike this
-- directory's other large-input XSLOW entries, which fail in a cheap,
-- contained way -- a stack overflow, or a bounded timeout -- and don't
-- carry a starting worse-than-linear memory blowup).
--
-- Measured directly (peak RSS, one clean run each): n=6 (720
-- solutions) ~54MB, n=7 (5040 solutions) ~738MB, n=8 (40320 solutions)
-- exceeded 4GB before completing even a third of them. That's a much
-- worse than n!-linear blowup -- consistent with this stage of the
-- runtime having no GC yet (docs/history/status-2026-09.md), so nothing explored and
-- discarded during the backtracking search is ever reclaimed; total
-- memory tracks *cumulative* work done, not what's actually still
-- live. Do not casually bump this back up without re-measuring peak
-- RSS the same way first (`ps -o rss=` on a monitored, timeout-capped
-- run) -- the jump from n=7 to n=8 alone is over 5x.
--
-- n=6 kept here (rather than reusing the identical size already
-- covered by tests/programs/regressions/ndperm.curry) because this
-- program's own point is different: not #4's copy-collapse soundness,
-- but nf_all actually enumerating a whole nondeterministic solution
-- set (via the `&`/`&>`-based N-queens filter on top of the same
-- ndinsert-permutation shape), not stopping at the first one.
insert :: a -> [a] -> [a]
insert x []     = [x]
insert x (y:ys) = x:y:ys ? y : (insert x ys)

perm :: [a] -> [a]
perm []     = []
perm (x:xs) = insert x (perm xs)

valid :: Int -> Int -> [Int] -> Bool
valid _ _  []     = True
valid q dq (c:cs) = abs (c - q) /= dq &
                    valid q (dq+1) cs &
                    valid c 1 cs

main :: [Int]
main = case perm [1..6] of
            (q:qs) -> valid q 1 qs &> (q:qs)

