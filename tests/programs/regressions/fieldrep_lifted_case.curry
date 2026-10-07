-- ICurry lifts a nested case into a new function (f_CASE<n>) whose
-- parameters include f's raw Int# variables. Those functions weren't in
-- the field-rep table, so their raw parameters were described as
-- pointers; CHECK_LAYOUT catches a raw value in a pointer slot where the
-- node is built. Output checked against KiCS2.
-- rice-flags: --cflags=-DCHECK_LAYOUT=1
f :: Int -> Int
f x = case x of
        0 -> 1
        n -> n * f (n - 1)

main :: IO ()
main = do print (f 5)
          print (map f [0, 1, 2, 3])
