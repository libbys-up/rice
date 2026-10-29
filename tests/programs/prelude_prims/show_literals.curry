-- Exercises the show*Literal external primitives (runtime/ext/Prelude.c's
-- hand-written _hnf functions, not inlined like the arithmetic table):
-- prim_showIntLiteral, prim_showFloatLiteral, prim_showCharLiteral,
-- prim_showStringLiteral (via ordinary `show`/`print` on each literal
-- type, and derived Show for a tuple/list of them).
main :: [String]
main =
  [ show (42 :: Int)
  , show (-7 :: Int)
  , show (3.5 :: Float)
  , show 'x'
  , show "hello"
  , show (1 :: Int, 'a', "bc", 2.5 :: Float)
  , show [1,2,3 :: Int]
  ]
