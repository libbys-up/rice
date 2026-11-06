-- rice-flags: --cflags=-DGC_STRESS
-- Data.IORef (runtime/ext/Data.IORef.c). A ref is a box pointing at a
-- cell; writes change the cell, so every copy of the box sees them.
import Data.IORef

main :: IO ()
main = do
  r <- newIORef (0 :: Int)
  let inc = modifyIORef r (+ 1)
  inc >> inc
  mapM_ (\_ -> inc) [1 .. 6]
  readIORef r >>= print
  s <- newIORef "a"
  writeIORef s "b"
  x <- readIORef s
  writeIORef s "c"
  y <- readIORef s
  print (x, y)
  t <- newIORef (length [1 .. 2000])
  a <- readIORef t
  b <- readIORef t
  print (a + b)
  let rs = [r, r]
  mapM_ (\q -> modifyIORef q (* 2)) rs
  readIORef r >>= print
  big <- newIORef []
  mapM_ (\i -> modifyIORef big (i :)) [1 .. 2000 :: Int]
  readIORef big >>= print . foldr (+) 0
