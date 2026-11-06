-- A non-tail recursion a million calls deep. Each pending `1 + len t`
-- used to be a nested C call (the case loop's HNF on its scrutinee), so
-- the depth this could reach was bounded by the C stack; on the
-- evaluation machine each one is a frame on Rice's own stack instead.
len :: [Int] -> Int
len xs = case xs of
           []    -> 0
           _ : t -> 1 + len t

main :: IO ()
main = print (len [1 .. 1000000])
