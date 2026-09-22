g :: Bool -> Bool
g True  = failed
g False = False

f :: Bool -> Bool -> Int
f True  y = case y of False -> 1
f False y = case y of False -> 2

main :: Int
main = let c = True ? False in f c (g c)
