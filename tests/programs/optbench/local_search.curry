-- optbench: #3 (scoped backtracking).
-- Each `isqrt k` searches the digits locally: the case in `check` fails
-- for every wrong guess. With #3 the failure flips the guess inside
-- `check`. Without it, every failure backtracks globally, and nf_all
-- re-walks the result list from the top before it gets back to the
-- failed element, so the work is quadratic in the list's length.
digit :: Int
digit = 0 ? 1 ? 2 ? 3 ? 4 ? 5 ? 6 ? 7 ? 8 ? 9

check :: Int -> Int -> Int
check k d = case d * d == k of True -> d

isqrt :: Int -> Int
isqrt k = check k digit

squares :: Int -> [Int]
squares n = if n == 0 then [] else ((n `mod` 10) * (n `mod` 10)) : squares (n - 1)

total :: Int -> [Int] -> Int
total acc []     = acc
total acc (y:ys) = (total $! (acc + y)) ys

main :: Int
main = total 0 (map isqrt (squares 40000))
