-- The externals of library modules in rice's lib/ (runtime/ext/*.c):
-- System.IO's handles, System.Environment and Curry.Compiler.Distribution.
import System.IO
import System.Environment
import Curry.Compiler.Distribution

main :: IO ()
main = do
  -- write a file through a handle, then read it back a character at a time
  h <- openFile "lib_externals.tmp" WriteMode
  hPutStr h "abc"
  w <- hIsWritable h
  hClose h
  r <- openFile "lib_externals.tmp" ReadMode
  rd <- hIsReadable r
  c1 <- hGetChar r
  rest <- hGetContents r
  print (w, rd, c1, rest)
  h2 <- openFile "lib_externals.tmp" AppendMode
  hPutStrLn h2 "def"
  hClose h2
  readFile "lib_externals.tmp" >>= putStr
  e <- openFile "lib_externals.tmp" ReadMode
  _ <- hGetLine e
  eof <- hIsEOF e
  hClose e
  print eof
  print (stdout == stdout, stdout == stderr)
  -- the environment
  setEnv "RICE_EXT_TEST" "hello"
  getEnv "RICE_EXT_TEST" >>= putStrLn
  unsetEnv "RICE_EXT_TEST"
  getEnv "RICE_EXT_TEST" >>= print
  getArgs >>= print
  getProgName >>= putStrLn
  print isWindows
  -- which compiler this is
  putStrLn curryCompiler
  print (curryCompilerMajorVersion, curryCompilerMinorVersion)
