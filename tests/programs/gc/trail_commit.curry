-- rice-mode: interactive
-- rice-flags: --cflags=-DGC_STRESS
--
-- Trail liveness (runtime/gc.c, trail_liveness) across bindIO commits.
-- c's choice is made before the IO actions run, so its entry is below
-- every commit height. Inside each action the loop's rewrites depend on c
-- and are trailed above the commit height; bindIO's pop_to then discards
-- them, without restoring anything. After the first solution, nf_all
-- backtracks below all of it, to c's other alternative, which has to see
-- the program as it was before the actions ran.
sumStrict :: Int -> [Int] -> Int
sumStrict acc xs = case xs of
  []     -> acc
  y : ys -> (sumStrict $! (acc + y)) ys

main :: IO ()
main = let c = 0 ? 1
           xs = [1 .. 20000]
       in c `seq` do print (sumStrict c xs)
                     d <- return (c + 1 ? c + 2)
                     print (sumStrict d xs)
                     print (c, d)
