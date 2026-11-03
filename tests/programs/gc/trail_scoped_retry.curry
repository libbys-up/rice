-- rice-mode: interactive
-- rice-flags: --cflags=-DOPT_SCOPED_BACKTRACK=1 --cflags=-DGC_STRESS
--
-- Trail liveness (runtime/gc.c, trail_liveness) under scoped backtracking
-- (#3). f's case retries its scrutinee by undoing only down to its own
-- cutoff, partway down the trail: the outer choice o is below it. The
-- loops between choices trail a lot, and major collections in them drop
-- and compact entries, so the cutoff held in f's frame has to be remapped
-- to the same segment boundary, and o's entry has to survive.
sumStrict :: Int -> [Int] -> Int
sumStrict acc xs = case xs of
  []     -> acc
  y : ys -> (sumStrict $! (acc + y)) ys

pick :: Int
pick = 1 ? 2 ? 3 ? 4 ? 5

check :: Int -> Int -> Bool
check o v = case sumStrict v [1 .. 2000] == 2001000 + o + 3 of
  True -> True

f :: Int -> Int
f o = case check o pick of
  True -> o + sumStrict o [1 .. 2000]

main :: Int
main = let o = 0 ? 1 ? 2 in f o
