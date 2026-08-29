module Data.Logic.DList where

-- Implements logic programming differences lists.
-- Unfortunately, because of the way Kics2 represents free variables,
-- these are not efficuent using Kics2.
-- This really only works if free variables can be filled in by updating a pointer
-- instead of using a generator function.
data DList a = DList [a] [a]

(:>) :: Data a => a -> DList a -> DList a
x :> (DList xs t) = DList (x:xs) t

(<:) :: Data a => DList a -> a -> DList a
(DList xs (x:t)) <: x = DList xs t

nil :: Data a => DList a
nil = DList t t 
 where t free

singleton :: Data a => a -> DList a
singleton x = DList (x:t) t
 where t free

fromlist :: Data a => [a] -> DList a
fromlist xs = DList (xs ++ t) t
 where t free

tolist :: Data a => DList a -> [a]
tolist (DList xs []) = xs

(++>) :: Data a => DList a -> DList a -> DList a
(DList l r) ++> (DList r y) = DList l y

