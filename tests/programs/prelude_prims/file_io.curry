-- readFile/writeFile/appendFile all bottom out in runtime/prelude.c
-- stubs (Prelude__prim_USreadFile_hnf etc.), each `error("file I/O not
-- implemented yet", root)`. XFAIL until implemented -- see
-- tests/manifest.txt.
main :: IO ()
main = do
  writeFile "stub_file_io.tmp" "hello\n"
  s <- readFile "stub_file_io.tmp"
  appendFile "stub_file_io.tmp" "more\n"
  putStr s
