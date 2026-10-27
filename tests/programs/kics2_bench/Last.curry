-- From KiCS2's benchmark suite (kics2/benchmarks/suite/Last.curry), with
-- one change for the modern frontend: the Data constraint on last's free variables.

last :: Data a => [a] -> a
last l | xs ++ [x] =:= l = x where xs,x free

goal0 = last (replicate 10000 True)
goal1 = last (replicate 100000 True)

main = goal1