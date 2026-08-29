
module Data.Functional.DList where

instance Monoid (DList a) where
    mempty  = nil
    mappend = (++>)

newtype DList a = DList ([a] -> [a])

fromList :: [a] -> DList a
fromList xs = DList (xs++)

toList :: DList a -> [a]
toList (DList fxs) = fxs []

(++>) :: Data a => DList a -> DList a -> DList a
(DList fl) ++> (DList fr) = DList (fl . fr)

(:>) :: a -> DList a -> DList a
x :> (DList fx) = DList ((x:) . fx)

(<:) :: Data a => DList a -> a -> DList a
(DList fx) <: x = DList (fx . (x:))

nil :: DList a
nil = DList id

singleton :: a -> DList a
singleton x = DList (x:)
