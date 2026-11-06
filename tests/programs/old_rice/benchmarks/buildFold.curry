
f :: Int -> Int
f n = foldr (+) 0 $
      map (+1) $
      map (+1) $
      map (+1) $
      map (+1) $
      map (+1) $
      map (+1) $
      map (+1) $
      [1..n]

main :: Int
main = f 1000000
