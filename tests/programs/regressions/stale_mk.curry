-- #1+#5 write barrier, minimal (developer's manual, "Soundness rules"). `p` is old and
-- rewritten deterministically to `(n, ())` with `n` new; `n` is then
-- rewritten nondeterministically. Without the barrier #1 skips `p`'s
-- entry and #5 skips `n`'s (young), so after backtracking `fst p` still
-- reads the first alternative's value. Rice normalizes a tuple's last
-- field first, so `b` is last here: its choice has to come before `p` is
-- evaluated for `n` to be young (the notes write `(b, fst p)`).
mk :: Bool -> (Bool, ())
mk b = (not b, ())

main :: (Bool, Bool)
main = let b = True ? False
           p = mk b
       in (fst p, b)
