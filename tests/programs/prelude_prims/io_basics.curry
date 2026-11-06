-- Exercises the core IO externals: bindIO, returnIO, prim_putChar
-- (runtime/ext/Prelude.c's hand-written _hnf functions) via ordinary
-- do-notation sequencing (>>=/>>/return desugar to bindIO/returnIO).
main :: IO ()
main = do
  putStr "abc"
  putStrLn ""
  putStrLn "line1"
  return () >>= \_ -> putStrLn "line2"    -- exercises bindIO/returnIO directly
  mapM_ putChar "line3"                   -- exercises prim_putChar in a loop
  putStrLn ""
  let x = 1 + 1
  x `seq` putStrLn ("x=" ++ show x)       -- exercises $! by way of seq/strictApply
