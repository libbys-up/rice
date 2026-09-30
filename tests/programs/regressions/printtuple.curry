-- print_tuple (runtime.c) printed a tuple's components in reverse: it
-- counted its index argument *down* from arity-1 to 0, printing each
-- component *before* recursing -- so under forward child storage (where
-- index 0 really is the first component) it printed the last component
-- first and the first component last. `(1,2,3)` printed as `(3, 2, 1)`.
-- See printlist.curry/printstring.curry for the same reversed-storage
-- assumption in this file's other two printing functions.
main :: (Int,Int,Int,Int,Int)
main = (1,2,3,4,5)
