-- Nondeterministic-insert permutation (docs/history/backtracking-optimizations.md's #4,
-- copy-instead-of-forward at collapse points): the user's own earlier
-- attempt at constructor copying was found unsound permuting lists of
-- length >= 5, though possibly a bug in that code rather than the idea
-- itself. Length 6 (720 solutions) here specifically to clear that
-- threshold while staying fast enough for the default (non-SLOW) suite;
-- tests/programs/old_rice/benchmarks/perm.curry is the same shape at 9
-- elements (362880 solutions, SLOW) for a larger cross-check. Verify
-- under both OPT_COPY_COLLAPSE=0 (default) and
-- RICE_CFLAGS=-DOPT_COPY_COLLAPSE=1 -- this program is exactly the shape
-- that needs collapse_safe to exclude FREE_TAG and collapse to preserve
-- root's own nondet bit around set_copy (see docs/history/status-2026-09.md's account of the
-- two bugs #4 needed fixing).
ndinsert :: a -> [a] -> [a]
ndinsert x []     = [x]
ndinsert x (y:ys) = x : y : ys ? y : ndinsert x ys

perm :: [a] -> [a]
perm []     = []
perm (x:xs) = ndinsert x (perm xs)

main :: [Int]
main = perm [1..6]
