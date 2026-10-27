-- From PAKCS's examples (pakcs/examples/First.curry), unchanged apart from
-- the main at the end, which runs one of its goals.
-- Lazy functional logic programming with infinite lists

data Nat = O | S Nat

first :: Nat -> [a] -> [a]
first O     _      = []
first (S n) (x:xs) = x : first n xs

from :: Nat -> [Nat]
from n = n : from (S n)

goal1 :: [Nat]
goal1     = first (S (S O)) (from O)

goal2 :: Nat -> Nat -> Bool
goal2 x y = first x (from y) =:= [O]

-- Added for rice:
main :: (Nat, Nat)
main | goal2 x y = (x, y) where x, y free
