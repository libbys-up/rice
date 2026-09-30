-- Higher-order functions and closures -- adapted from kics2's
-- testsuite/LanguageTests/TestHigher.curry, rewritten as a plain main
-- instead of Test.Prop properties (see tests/README.md).

map_ :: (a -> b) -> [a] -> [b]
map_ _ []     = []
map_ f (x:xs) = f x : map_ f xs

foldr_ :: (a -> b -> b) -> b -> [a] -> b
foldr_ _ z []    = z
foldr_ f z (h:t) = f h (foldr_ f z t)

inc :: Int -> Int
inc x = x + 1

main :: Int
main = foldr_ (+) 0 (map_ inc [0,2,1])
