-- Scaled-up copy of tests/programs/kics2_bench/PaliFunPats.curry, for optbench.sh's timing:
-- longPali 700 instead of 100.

-- From KiCS2's benchmark suite (kics2/benchmarks/suite/PaliFunPats.curry), with
-- one change for the modern frontend: the Data constraint on pali's functional patterns.
--------------------------------------------------------------------------------
-- define a palindrome constraint with functional patterns:
pali :: Data a => [a] -> Success
pali (xs ++ reverse xs) = success
pali (xs ++ _ : reverse xs) = success

test1 = pali [True,False,True] --> success
test2 = (pali [True,False,False,True]) --> success
test3 = (pali [True,False]) --> fail

longPali n = take n (repeat True) ++ take n (repeat False) ++ [False] ++
             take n (repeat False) ++ take n (repeat True)

main = pali (longPali 700)