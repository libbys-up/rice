
(+-+) :: [a] -> [a] -> [a]
[] +-+ ys = ys
(x:xs) +-+ ys = x : (xs+-+ys)

rep :: Int -> a -> [a]
rep n a = case n of
               0 -> []
               _ -> a : rep (n-1) a

last :: (Eq a) => [a] -> a
last xs = case (ys+-+[x]) == xs of
               True -> x
 where x, ys free

main :: Bool
main = last (rep 20000 True)
