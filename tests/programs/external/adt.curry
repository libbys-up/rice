-- User-defined algebraic data types and pattern matching over them --
-- a small binary tree, in the spirit of the ADT-heavy examples throughout
-- kics2's testsuite (e.g. TestNarrowing.curry's own tree type), kept
-- self-contained here.

data Tree = Leaf | Node Tree Int Tree

insert :: Int -> Tree -> Tree
insert x Leaf = Node Leaf x Leaf
insert x t@(Node l y r)
  | x < y     = Node (insert x l) y r
  | x > y     = Node l y (insert x r)
  | otherwise = t

size :: Tree -> Int
size Leaf         = 0
size (Node l _ r) = 1 + size l + size r

fromList :: [Int] -> Tree
fromList = foldr insert Leaf

main :: Int
main = size (fromList [5,3,8,3,1,8,9])
