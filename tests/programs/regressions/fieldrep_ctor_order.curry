-- print_final walked a constructor's children last-to-first (the old
-- reversed-storage convention), printing T 1 True 'x' as T('x', True, 1).
-- Field order checked against KiCS2 ((T 1 True 'x')); the T(...) syntax
-- is Rice's own.
data T = T Int Bool Char

main :: (T, [T])
main = (T 1 True 'x', [T 2 False 'y'])
