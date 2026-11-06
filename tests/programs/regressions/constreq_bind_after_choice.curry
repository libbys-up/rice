-- constrEq binding a free variable after a choice point, inside a shared
-- node: the binding is undone on backtracking, so root must be trailed
-- too (unify_step sets nondet on every binding). Checked with PAKCS.
f :: Bool -> Bool -> Bool
f True  z = z
f False z = z

main :: (Bool, Bool)
main = let x = True ? False
           y free
           z = y =:= True
       in (f x z, y)
