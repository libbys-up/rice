-- #1+#5 write barrier: `n` (built by `mk`'s deterministic rewrite of `p`)
-- is first reached through `pick`'s node, not through `p`. A barrier that
-- tracks the evaluation path instead of allocation stamps gets this
-- wrong (developer's manual, "Soundness rules"). The fields are in
-- the reverse of the notes' order, because Rice normalizes a tuple's last
-- field first: `b`'s choice comes first, then `pick b p` reaches `n`.
mk :: Bool -> (Bool, ())
mk b = (not b, ())

pick :: Bool -> (Bool, ()) -> Maybe Bool
pick True  p = Just (fst p)
pick False _ = Nothing

main :: (Bool, Maybe Bool, Bool)
main = let b = True ? False
           p = mk b
       in (fst p, pick b p, b)
