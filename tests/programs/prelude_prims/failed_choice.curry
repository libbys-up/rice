-- Exercises `failed` (fails unconditionally, backing pattern-match
-- failure and used directly here) together with `(?)`: a failed
-- alternative must be silently skipped by nf_all's own backtracking,
-- not printed and not crash the search.
main :: Int
main = (failed ? 1) ? (2 ? failed)
