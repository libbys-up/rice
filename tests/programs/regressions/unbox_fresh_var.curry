-- Unbox gives the literal case on k a new box variable. Its number has to
-- be fresh: before the fix it was k's own number, so the box pattern
-- shadowed k, and the field rep lint rejected the program.
g :: Maybe Int -> Int
g Nothing    = 0
g (Just k@1) = k + 10
g (Just k@2) = k + 20

main :: [Int]
main = [g Nothing, g (Just 1), g (Just 2)]
