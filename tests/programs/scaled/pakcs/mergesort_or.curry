-- Scaled-up copy of tests/programs/pakcs_examples/mergesort_or.curry, for optbench.sh's timing:
-- Sorts 3000 pseudo-random Ints instead of goal3's 13, and prints a
-- checksum of the result instead of the list.

-- From PAKCS's examples (pakcs/examples/mergesort_or.curry), unchanged apart from
-- the main at the end, which runs one of its goals.

goal1 xs = sort intMerge [3,1,2] xs
goal2 xs = sort intMerge [3,1,2,5,4,8] xs
goal3 xs = sort intMerge [3,1,2,5,4,8,6,7,2,9,1,4,3] xs


sort :: Data a => ([a] -> [a] -> [a] -> Bool) -> [a] -> [a] -> Bool
sort merge xs ys =
   if length xs < 2 then ys =:= xs
   else sort merge (firsthalf xs) us
        & sort merge (secondhalf xs) vs
        & merge us vs ys
   where us,vs free


intMerge :: [Int] -> [Int] -> [Int] -> Bool

intMerge [] ys zs =  zs =:= ys
intMerge xs [] zs =  zs =:= xs
intMerge (x:xs) (y:ys) zs =
   if (x > y) then intMerge (x:xs) ys us & zs =:= y:us
              else intMerge xs (y:ys) vs & zs =:= x:vs
   where us,vs free

  
firsthalf  xs = take (length xs `div` 2) xs
secondhalf xs = drop (length xs `div` 2) xs


-- Added for rice:
-- A pseudo-random list of 3000 Ints; only its checksum is printed.
input :: [Int]
input = take 3000 (iterate (\x -> (x * 1103 + 12345) `mod` 10007) 1)

checksum :: [Int] -> Int
checksum = go 1 0
  where go _ acc []     = acc
        go i acc (y:ys) = go (i + 1) ((acc + i * y) `mod` 1000003) ys

main :: Int
main | sort intMerge input xs = checksum xs where xs free
