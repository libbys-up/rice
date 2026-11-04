-- Running an action rewrites its node with the result, so bindIO runs a
-- fresh copy of a shared action each time (runtime/ext/Prelude.c). Every
-- use of a shared action has to run it again.
main :: IO ()
main = do
  let p = putStrLn "hi"
  p >> p
  let r = putStr "rep "
  sequence_ (replicate 3 r)
  putStrLn ""
  writeFile "shared_io.tmp" ""
  let a = appendFile "shared_io.tmp" "tw"
  a >> a >> a >> a
  s <- readFile "shared_io.tmp"
  putStrLn s
  let both = do x <- return "one"
                y <- return "two"
                return (x, y)
  t <- both
  u <- both
  print (t, u)
  let acts = [p, r >> putStrLn "", p]
  sequence_ acts
  sequence_ acts
  let q = putStrLn "inner" >> putStrLn "outer"
  q >> q
