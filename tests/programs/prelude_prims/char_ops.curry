-- Exercises Char-related external primitives: eqChar, ltEqChar,
-- ord, chr (replace_Prim.curry/PrimOps.curry).
main :: [Int]
main =
  [ if 'a' == 'a' then 1 else 0   -- eqChar (True)
  , if 'a' == 'b' then 1 else 0   -- eqChar (False)
  , if 'a' <= 'b' then 1 else 0   -- ltEqChar
  , if 'b' <= 'a' then 1 else 0   -- ltEqChar (False)
  , ord 'A'                        -- prim_ord
  , if chr 65 == 'A' then 1 else 0 -- prim_chr, round-trip
  , ord (chr (ord 'z'))             -- chr/ord round-trip
  ]
