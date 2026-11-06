-- #1+#3: f's outer case reads a nondeterministic x (chosen before f is
-- entered); its inner case reads a deterministic y and has no branch for
-- it. The inner case's own nondet flag is false, so a fail write gated
-- on it is untrailed, and f's node stays FAIL after backtracking flips x
-- (developer's manual, "Soundness rules", #3).
-- Rice lifts the inner case into its own function (f_CASE0), so the
-- inner case is a separate rewrite whose fail is undone by the entry f's
-- own case pushed: this passed before the fix too. It guards the shape.
f :: Bool -> Bool -> Bool
f x y = case x of
  True  -> case y of True -> True
  False -> False

main :: (Bool, Bool)
main = let x = True ? False in (x, f x False)
