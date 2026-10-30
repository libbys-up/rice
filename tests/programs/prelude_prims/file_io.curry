-- readFile/writeFile/appendFile (runtime/ext/Prelude.c). readFile is lazy,
-- so the string is forced before the file is appended to: reading a file
-- lazily while writing it isn't defined (KiCS2 stops with "resource busy").
-- A failure (missing file, permission denied, ...) is fatal, since `catch`
-- is still a stub; not exercised here for that reason.
main :: IO ()
main = do
  writeFile "file_io.tmp" "hello\n"
  s <- readFile "file_io.tmp"
  length s `seq` appendFile "file_io.tmp" "more\n"
  putStr s
  readFile "file_io.tmp" >>= putStr
