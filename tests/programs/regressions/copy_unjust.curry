-- #1+#4: unjust's rewrite reads only the Just cell, so it's
-- deterministic. Copying q's value into it (instead of forwarding) is only
-- safe if q's own nondet flag is checked: otherwise the copy of True
-- survives backtracking into q (developer's manual, "Soundness rules", #4).
unjust :: Maybe a -> a
unjust (Just v) = v

main :: (Bool, Bool)
main = let q = True ? False in (q, unjust (Just q))
