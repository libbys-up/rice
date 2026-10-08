-- Long IO chains through bindIO: a right-nested loop (each step pending
-- only a commit frame) and a left-nested chain (settling m recurses
-- through the whole chain). Both run on the evaluation machine.
loop :: Int -> IO ()
loop n = if n == 0 then putStrLn "right-nested done"
                   else return () >> loop (n - 1)

main :: IO ()
main = do loop 200000
          foldl (>>) (return ()) (replicate 200000 (return ()))
          putStrLn "left-nested done"
