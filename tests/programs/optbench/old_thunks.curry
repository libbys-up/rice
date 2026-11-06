-- optbench: #1 (nondet-gated trailing).
-- 200,000 shared thunks are built before a choice and evaluated after it.
-- Their rewrites read nothing nondeterministic, so #1 doesn't trail them.
-- They're older than the choice, so #5 still does.
sq :: Int -> Int
sq x = x * x

sumL :: Int -> [Int] -> Int
sumL acc []     = acc
sumL acc (y:ys) = (sumL $! (acc + y)) ys

main :: (Bool, Int)
main = let xs = map sq [1..200000]
       in if length xs > 0
            then let b = True ? False in (b, sumL 0 xs)
            else failed
