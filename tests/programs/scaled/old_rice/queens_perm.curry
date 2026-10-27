-- Scaled-up copy of tests/programs/old_rice/benchmarks/queens_perm.curry, for optbench.sh's timing:
-- 8 queens instead of 6: 40,320 permutations, 92 solutions. The original
-- was cut to 6 when there was no collector; peak RSS is now about 75MB.

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
main = case perm [1..8] of
            (q:qs) -> valid q 1 qs &> (q:qs)
