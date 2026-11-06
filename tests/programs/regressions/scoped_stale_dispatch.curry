-- #3 alone: the choice is made by f's outer case, inside f. The inner case
-- fails, and a retry scoped to the whole function flips the choice but
-- re-runs only the inner case loop, which re-reads y; the outer dispatch
-- on x is never redone (developer's manual, "Soundness rules", #3).
-- Rice lifts the inner case into its own function, whose retry scope
-- never covered the outer choice, so this passed before the fix too. The
-- per-case retry cutoff covers nesting that isn't lifted.
f :: Bool -> Bool -> Bool
f x y = case x of
  True  -> case y of True -> True
  False -> False

main :: Bool
main = f (True ? False) False
