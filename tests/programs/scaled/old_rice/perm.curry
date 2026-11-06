-- Scaled-up copy of tests/programs/old_rice/benchmarks/perm.curry, for optbench.sh's timing:
-- Permutations of [1..9] (362,880) instead of [1..6]. Only the one with
-- the least weight (sum of i * p_i) is printed, [9,8..1]; the weight
-- needs the whole permutation, so no permutation is cut short.

insert :: a -> [a] -> [a]
insert x [] = [x]
insert x (y:ys) = x:y:ys ? y : (insert x ys)

perm :: [a] -> [a]
perm [] = []
perm (x:xs) = insert x (perm xs)

weight :: [Int] -> Int
weight xs = go 1 xs
  where go _ []     = 0
        go i (y:ys) = i * y + go (i + 1) ys

main :: [Int]
main = let p = perm [1..9] in weight p == 165 &> p
