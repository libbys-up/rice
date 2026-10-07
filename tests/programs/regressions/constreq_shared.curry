-- Same constrEq bug as constreq_choice: the shared root stayed True after
-- backtracking, giving the impossible (True, False). Checked with PAKCS.
main :: (Bool, Bool)
main = let x = True ? False
       in (x =:= True, x)
