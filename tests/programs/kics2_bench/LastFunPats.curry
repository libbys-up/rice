-- From KiCS2's benchmark suite (kics2/benchmarks/suite/LastFunPats.curry), unchanged.
-- The classical function pattern:
last (_++[e]) = e

testlast n = last (map (const False) [1..n] ++ [True])

main = testlast 100000
