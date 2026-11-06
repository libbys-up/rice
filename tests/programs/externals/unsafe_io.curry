-- unsafePerformIO (runtime/ext/System.IO.Unsafe.c).
import System.IO.Unsafe
import Data.IORef

main :: IO ()
main = do
  let x = unsafePerformIO (putStrLn "once" >> return (5 :: Int))
  print (x + x)
  r <- newIORef (1 :: Int)
  let y = unsafePerformIO (readIORef r)
  writeIORef r 7
  print y
  print (unsafePerformIO (return 'z'))
