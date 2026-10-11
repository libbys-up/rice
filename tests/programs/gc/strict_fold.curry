-- A strict left fold over a lazily generated list: each cell is garbage
-- once consumed, so the live set stays a few nodes however long the list
-- is.
-- rice-maxrss: 150
sumStrict :: Int -> [Int] -> Int
sumStrict acc xs = case xs of
  []     -> acc
  y : ys -> (sumStrict $! (acc + y)) ys

main :: IO ()
main = do print (sumStrict 0 [1 .. 3000000])
          print (sumStrict 0 (map (* 2) (filter even [1 .. 2000000])))
