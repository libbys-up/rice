-- read/reads on primitive types (Int/Char/String/Float), backed by the
-- prim_read{Char,String,Nat,Float}Literal externals (runtime/prelude.c),
-- the inverse of show*Literal (show_literals.curry). Each is a genuine
-- prefix parser (`String -> [(a, String)]`, the standard ReadS
-- convention), with escaping the exact inverse of show's own
-- (appendEscaped, shared by both directions).
main :: (Int, Int, Char, String, Float, Float)
main =
  ( read "42" :: Int
  , read "-17" :: Int
  , read "'a'" :: Char
  , read "\"hello\"" :: String
  , read "3.5" :: Float
  , read "-2.5" :: Float
  )
