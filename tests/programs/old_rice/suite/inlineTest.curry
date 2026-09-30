data T = C (T -> Int)

g y = case y of
           C h -> h y

main = g (C g)
