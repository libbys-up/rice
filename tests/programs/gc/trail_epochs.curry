-- rice-mode: interactive
-- rice-flags: --cflags=-DOPT_EPOCH_TRAIL=1 --cflags=-DGC_STRESS
--
-- Trail liveness (runtime/gc.c, trail_liveness) under epoch trailing (#5).
-- Each choice is followed by a long loop whose rewrites depend on it, so
-- they're trailed, and major collections in the loops drop most of those
-- entries. undo and pop_to reload current_epoch from the bottom entry of
-- each segment, so a dead bottom entry has to stay, empty, with its epoch;
-- if the epoch were lost, a node allocated before a choice would look
-- younger than it, its rewrite would go untrailed, and a later alternative
-- would see the earlier one's result.
sumStrict :: Int -> [Int] -> Int
sumStrict acc xs = case xs of
  []     -> acc
  y : ys -> (sumStrict $! (acc + y)) ys

shared :: Int -> [Int]
shared n = [1 .. n]

main :: (Int, Int, Int, Int)
main = let a  = 0 ? 1 ? 2
           ys = shared 3000
           s  = sumStrict a ys
           b  = 10 ? 20
       in (s + b, a, sumStrict b ys, s)
