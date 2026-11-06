-- Collections while a choice is pending. The choices are made before a
-- long, allocating loop, so the trail and the choices' other branches
-- have to survive every collection in it, and backtracking has to find
-- the alternatives intact afterwards.
--
-- The loop's root node is rewritten in place on every iteration, and
-- each rewrite depends on `c`, so each one is trailed; every snapshot
-- keeps that iteration's list cell and accumulator alive. Only the oldest
-- snapshot per node between two backtracking stop points can ever be
-- restored, but the collector can't drop the others without knowing every
-- trail height held in frames (docs/history/gc-plan.md, stage 3). Until then this
-- uses memory in proportion to the loop: see manifest.txt.
-- rice-maxrss: 150
sumStrict :: Int -> [Int] -> Int
sumStrict acc xs = case xs of
  []     -> acc
  y : ys -> (sumStrict $! (acc + y)) ys

coin :: Int
coin = 0 ? 1

main :: Int
main = let c = coin
           n = 200000 ? 400000
       in c + sumStrict c [1 .. n] + c
