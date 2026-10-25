-- optbench: #4 (copy collapse) and path compression.
-- `v` is reached through a 200-long chain of forwards (each `idc`
-- collapses to its argument) and then read 20,000 times. Without either
-- optimization every read walks the chain. #4 copies the finished value
-- instead of forwarding to it, so there's no chain; path compression
-- retargets it on the first read.
idc :: a -> a
idc x = x

chain :: Int -> a -> a
chain n x = if n == 0 then x else idc (chain (n - 1) x)

reads :: Maybe Int -> Int -> Int -> Int
reads v acc k = if k == 0 then acc
                else case v of Just x -> (reads v $! (acc + x)) (k - 1)

main :: Int
main = let v = chain 200 (Just 1) in reads v 0 20000
