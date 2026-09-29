-- readFile/writeFile/appendFile: all three now real implementations in
-- runtime/prelude.c (whole-file, not lazy/streaming -- a separate,
-- bigger design question, same category as real exception handling).
-- A failure (missing file, permission denied, ...) is still fatal --
-- real Curry signals that as a catchable IOError, but exception
-- handling isn't designed yet (`catch` is still a stub) -- not
-- exercised here for that reason.
main :: IO ()
main = do
  writeFile "file_io.tmp" "hello\n"
  s <- readFile "file_io.tmp"
  appendFile "file_io.tmp" "more\n"
  putStr s
