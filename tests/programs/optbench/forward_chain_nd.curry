-- optbench: path compression under a pending choice.
-- Like forward_chain, but the chain ends in a choice, so its last
-- forward is flagged. Compression may only skip the unflagged hops in
-- front of it, which is all but one.
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
main = let v = chain 200 (Just 1 ? Just 2) in total 0 (copies 200000 v)
