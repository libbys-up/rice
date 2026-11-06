-- Scaled-up copy of tests/programs/old_rice/benchmarks/fibPeano.curry, for optbench.sh's timing:
-- fib 30 instead of fib 10, printed as an Int (fib 30 in unary would
-- make an 832,040-S golden).

data N = Z | S N

add :: N -> N -> N
add Z     y = y
add (S x) y = S (add x y)

fib :: N -> N
fib Z         = Z
fib (S Z)     = S Z
fib (S (S x)) = add (fib (S x)) (fib x)

toPeano :: Int -> N
toPeano n = if n == 0 then Z else S (toPeano (n - 1))

toInt :: N -> Int
toInt Z     = 0
toInt (S x) = 1 + toInt x

main :: Int
main = toInt (fib (toPeano 30))
