-- optbench: the write barrier (#1+#5).
-- 100,000 shared `mk b i` thunks are built before the choice on `b` and
-- evaluated after it. Each one's rewrite is deterministic (it doesn't
-- read `b`), so #1 skips it, and it builds a young `pick b i` call that's
-- then rewritten nondeterministically. The barrier stamps that call as
-- old as its thunk, so #5 trails it. This is the barrier's worst case:
-- every node it lowers is later trailed.
pick :: Bool -> Int -> Int
pick b i = if b then i else 1

mk :: Bool -> Int -> (Int, ())
mk b i = (pick b i, ())

sumF :: Int -> [(Int, ())] -> Int
sumF acc []          = acc
sumF acc ((x,_):ys)  = (sumF $! (acc + x)) ys

main :: (Bool, Int)
main = let b  = True ? False
           ps = map (mk b) [1..100000]
       in if length ps > 0 then (b, sumF 0 ps) else failed
