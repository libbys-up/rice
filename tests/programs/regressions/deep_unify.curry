-- Unification over million-element lists: =:= walks both normal forms
-- with an explicit work list, and =:<= unifies one pair per frame on the
-- evaluation machine. Both used to recurse one C call per element.
main :: IO ()
main = do print ([1 .. 1000000 :: Int] =:= [1 .. 1000000])
          print (xs =:<= [1 .. 1000000 :: Int] &> length xs)
  where xs free
