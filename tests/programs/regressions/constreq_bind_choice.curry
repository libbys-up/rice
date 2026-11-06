-- constrEq binding a free variable to a value that depends on a choice:
-- the root must be trailed so the binding is redone on retry, not left
-- free. Checked with PAKCS.
f :: Bool -> Bool
f b = b

main :: (Bool, Bool)
main = let x = True ? False
           y free
       in (f x =:= y, y)
