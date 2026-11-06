-- A large structure that stays live across several collections has to
-- come out of each one intact: build a list, churn through enough garbage
-- to collect a few times, then read the list again.
-- rice-maxrss: 300
sumStrict :: Int -> [Int] -> Int
sumStrict acc xs = case xs of
  []     -> acc
  y : ys -> (sumStrict $! (acc + y)) ys

main :: IO ()
main = do let xs = map (\x -> x * 3 + 1) [1 .. 300000]
          print (sumStrict 0 xs)
          print (sumStrict 0 [1 .. 4000000])
          print (sumStrict 0 xs)
          print (length xs, xs !! 123456)
