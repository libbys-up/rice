
g :: Bool -> Bool -> Bool
g x _ = x

f :: Bool -> Bool
f x = let y = g x x
      in g x y
