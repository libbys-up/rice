-- =:= compares boxed values through their raw children: equal ones
-- unify, different ones fail, so only the first alternative is a
-- solution. Checked against KiCS2.
data T = T Int Char

main :: (Int, Char)
main = good ? bad
 where
  good | T a b =:= T 7 'z' = (a, b) where a, b free
  bad  | T 1 'c' =:= T 2 'c' = (0, 'n')
