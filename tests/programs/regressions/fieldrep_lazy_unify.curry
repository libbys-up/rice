-- =:<= narrowed a free variable to the other side's constructor with a
-- free variable in every child, including a box's raw slot, so x =:<= 3
-- wrote a free-variable pointer where the raw Int goes. Raw children now
-- take the other side's value. Checked against KiCS2.
data T = T Int Char

main :: (Int, T)
main | x =:<= 3 & y =:<= T 4 'q' = (x, y)
  where x, y free
