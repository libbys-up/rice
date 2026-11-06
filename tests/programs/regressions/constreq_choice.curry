-- (=:=) rewrote its root to True without trailing it, even when nf() of a
-- side resolved a choice (constrEq ignored nondet), so backtracking left
-- root True and the second alternative also printed True. Correct
-- answers checked with PAKCS.
main :: Bool
main = (True ? False) =:= True
