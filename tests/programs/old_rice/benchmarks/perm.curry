-- Reduced from the original [1..9] (362880 permutations, no pruning --
-- unlike queens_perm.curry below, nothing here rejects any of them)
-- after its golden ballooned to 13MB, a repo-bloat hazard rather than a
-- cheap/contained cost like this directory's other SLOW entries.
--
-- [1..6] (720 permutations) matches queens_perm.curry's own reduction
-- exactly, for the same reason: a 20KB golden and a ~0.2s run, measured
-- directly -- fast enough to no longer need the SLOW tag at all
-- (dropped from manifest.txt). Kept as a separate test from
-- queens_perm.curry/ndperm.curry anyway: this one has no N-queens
-- filter at all, so it's the plain "enumerate every permutation" case
-- those build on.
insert :: a -> [a] -> [a]
insert x [] = [x]
insert x (y:ys) = x:y:ys ? y : (insert x ys)

perm :: [a] -> [a]
perm [] = []
perm (x:xs) = insert x (perm xs)

main :: [Int]
main = perm [1..6]
