-- foldr with a class method applies (+) through `apply` nodes, so every
-- pending level goes through apply_hnf. With apply on the evaluation
-- machine, a million levels need no C stack.
main :: IO ()
main = print (foldr (+) 0 [1 .. 1000000])
