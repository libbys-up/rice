-- optbench: path compression and #4 under a pending choice.
-- Like forward_chain, but the chain ends in a choice, so its last
-- forward is flagged: compression may only skip the unflagged hops in
-- front of it, and #4 may not copy a flagged value.
idc :: a -> a
idc x = x

chain :: Int -> a -> a
chain n x = if n == 0 then x else idc (chain (n - 1) x)

reads :: Maybe Int -> Int -> Int -> Int
reads v acc k = if k == 0 then acc
                else case v of Just x -> (reads v $! (acc + x)) (k - 1)

main :: Int
main = let v = chain 200 (Just 1 ? Just 2) in reads v 0 20000
