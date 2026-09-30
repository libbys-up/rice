-- List comprehensions -- in the same spirit as old_rice's own
-- queens_det.curry (which uses one for its search), isolated down to just
-- the comprehension feature itself: generators, a nested generator, and a
-- guard.

pairs :: [(Int,Int)]
pairs = [ (x,y) | x <- [1..4], y <- [1..4], x < y ]

main :: Int
main = length pairs
