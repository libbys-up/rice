-- optbench: path compression.
-- `v` heads a 200-long chain of forwards, and a 1,200,000-element list has
-- `v` in every slot. Each `idc 0 x` collapses to `x` while `x` is still
-- a thunk, so it's a forward, not a copy, and #4 can't help. (`idc` is
-- recursive so the inliner leaves it alone; inlined, there'd be no
-- chain.) Without compression, reading each element walks the whole
-- chain from `v`; a reader's own slot moves to the end, but the next
-- element's slot still points at `v`. With compression, the first read
-- retargets `v` and the rest take one hop.
idc :: Int -> a -> a
idc k x = if k > 0 then idc (k - 1) x else x

chain :: Int -> a -> a
chain n x = if n == 0 then x else idc 0 (chain (n - 1) x)

copies :: Int -> a -> [a]
copies n x = if n == 0 then [] else x : copies (n - 1) x

total :: Int -> [Maybe Int] -> Int
total acc []     = acc
total acc (m:ms) = case m of Just x -> (total $! (acc + x)) ms

main :: Int
main = let v = chain 200 (Just 1) in total 0 (copies 1200000 v)
