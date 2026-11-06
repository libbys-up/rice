
f3 :: (a -> b -> c -> d) -> a -> b -> c -> d
f3 f x y z = f x y z

r :: Int -> Int -> Int -> Int
r a b c = a + b + c

main :: IO ()
main = print (f3 r 1 2 3)
