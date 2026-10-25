-- A choice is nondeterministic even in its last alternative. If taking
-- x's False were treated as deterministic, it would survive the retry of
-- y and (S Z, True) would be lost (backtracking_proofs.md, nondet
-- tracking rule 4).
data N = Z | S N

main :: (N, Bool)
main = let y = Z ? S Z
           x = True ? False
       in (y, x)
