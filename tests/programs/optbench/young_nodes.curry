-- optbench: #5 (epoch trailing).
-- After a choice, build and consume a 200,000-element list whose
-- elements depend on the choice. Those rewrites are nondeterministic, so
-- #1 trails them, but every node is younger than the choice, so #5
-- doesn't.
build :: Bool -> Int -> [Int]
build b n = if n == 0 then [] else (if b then n else 1) : build b (n - 1)

sumL :: Int -> [Int] -> Int
sumL acc []     = acc
sumL acc (y:ys) = (sumL $! (acc + y)) ys

main :: (Bool, Int)
main = let b = True ? False in (b, sumL 0 (build b 200000))
