-- Scaled-up copy of tests/programs/old_rice/benchmarks/ndtest.curry, for optbench.sh's timing:
-- fib 7 instead of fib 6: 2^21 (about 2 million) solutions instead of 8192.
-- Only the one where every leaf picks 1 is printed, so the golden stays
-- one line while the search covers them all.

fib :: Int -> Int
fib n
 | n < 2 = 0 ? 1
 | otherwise = fib (n-1) + fib (n-2)

main :: Int
main = let r = fib 7 in r == 21 &> r
