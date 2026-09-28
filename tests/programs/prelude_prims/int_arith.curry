-- Exercises every Int-related external primitive replace_Prim.curry
-- declares (Rice's own unboxed-Int representation, PrimOps.curry's
-- inline table): plusInt, minusInt, timesInt, divInt, modInt, quotInt,
-- remInt, eqInt, ltEqInt, plus the ordinary comparison operators built
-- on top of eqInt/ltEqInt (</>/>=/compare).
main :: [Int]
main =
  [ 3 + 4          -- plusInt
  , 10 - 3         -- minusInt
  , 6 * 7          -- timesInt
  , 17 `div` 5     -- divInt
  , 17 `mod` 5     -- modInt
  , 17 `quot` 5    -- quotInt
  , 17 `rem` 5     -- remInt
  , (-17) `div` 5  -- divInt, negative dividend (floor semantics: -4)
  , (-17) `mod` 5  -- modInt, negative dividend (result takes divisor's sign: 3)
  , (-17) `quot` 5 -- quotInt, negative dividend (truncate semantics: -3)
  , (-17) `rem` 5  -- remInt, negative dividend (result takes dividend's sign: -2)
  , if 4 == 4 then 1 else 0   -- eqInt (True case)
  , if 4 == 5 then 1 else 0   -- eqInt (False case)
  , if 4 <= 5 then 1 else 0   -- ltEqInt
  , if 5 <= 4 then 1 else 0   -- ltEqInt (False case)
  , if 4 < 5  then 1 else 0   -- derived from ltEqInt
  , if 5 > 4  then 1 else 0   -- derived from ltEqInt
  , if 4 >= 4 then 1 else 0   -- derived from ltEqInt
  , foldr1 max [3,1,4,1,5,9,2,6]  -- exercises comparisons across a list
  , foldr1 min [3,1,4,1,5,9,2,6]
  ]
