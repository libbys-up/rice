-- optbench: #4 (copy collapse).
-- Like forward_chain, but ``x `seq` x`` evaluates `x` before collapsing
-- to it, so every collapse lands on a finished value. #4 makes each one
-- a copy, so there's no chain at all. Without it there's the same
-- 200-long chain as forward_chain, which path compression also fixes,
-- though only after the first read walks it.
idc :: Int -> a -> a
idc k x = if k > 0 then idc (k - 1) x else x `seq` x

chain :: Int -> a -> a
chain n x = if n == 0 then x else idc 0 (chain (n - 1) x)

copies :: Int -> a -> [a]
copies n x = if n == 0 then [] else x : copies (n - 1) x

total :: Int -> [Maybe Int] -> Int
total acc []     = acc
total acc (m:ms) = case m of Just x -> (total $! (acc + x)) ms

main :: Int
main = let v = chain 200 (Just 1) in total 0 (copies 1200000 v)
