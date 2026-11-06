
aux :: (Int -> Int) -> Int
aux f = f 1 + f 10

r :: Int -> Int -> Bool -> Int
r x y b = aux (\z -> x + z) *
          aux (\z -> if b then y + z else y - z)


