-- Case expressions with guarded branches -- adapted from kics2's
-- testsuite/LanguageTests/TestCase.curry (posFirstOrSecond), rewritten as
-- a plain main instead of a Test.Prop property (Rice doesn't implement
-- Test.Prop; see tests/README.md).

posFirstOrSecond :: [Int] -> Int
posFirstOrSecond zs = case zs of
  (x:_)   | x > 0 -> x
  (_:y:_) | y > 0 -> y
  _               -> 0

main :: Int
main = posFirstOrSecond [0,2,3]
