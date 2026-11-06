-- An IO action whose value fails stops the program. bindIO used to hand
-- the failure to the continuation, and `>>` ignores its argument, so the
-- program carried on as if the action had run: a failed `read` made a
-- print vanish without a word.
-- rice-exit: 1
main :: IO ()
main = do
  putStrLn "before"
  print (head ([] :: [Int]))
  putStrLn "after"
