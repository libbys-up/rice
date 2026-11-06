-- (=:<=) version of constreq_bind_after_choice: lazy_unify_step's plain
-- binding branch didn't report nondet, so root stayed True while the
-- binding was undone, printing (True, free). Checked with PAKCS.
f :: Bool -> Bool -> Bool
f True  z = z
f False z = z

main :: (Bool, Bool)
main = let x = True ? False
           y free
           z = y =:<= True
       in (f x z, y)
