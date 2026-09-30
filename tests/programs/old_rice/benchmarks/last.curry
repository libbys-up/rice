
rep :: Int -> a -> [a]
rep n x = case n of
               0 -> []
               _ -> x : rep (n-1) x 

(+-+) :: [a] -> [a] -> [a]
[]     +-+ ys = ys
(x:xs) +-+ ys = x : (xs +-+ ys)

last :: [a] -> a
last ys | (xs +-+ [x]) =:= ys = x
  where xs, x free

main :: Bool
main = last (rep 1000000 True)
