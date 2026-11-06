-- readFile is lazy: a 2 MB file read by a strict count keeps a few
-- blocks live, not the whole string (96 bytes a character). The heap
-- limit below would fail if the whole file were read at once.
-- rice-maxrss: 150
count :: Int -> String -> Int
count n s = case s of
  []     -> n
  (_:cs) -> (count $! (n + 1)) cs

main :: IO ()
main = do
  writeFile "lazy_readfile.tmp" (concat (replicate 200000 "0123456789"))
  s <- readFile "lazy_readfile.tmp"
  print (count 0 s)
