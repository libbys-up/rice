-- (=:<=) against a choice nested in a constructor. lu_k's settle loops
-- used to treat a CHOICE node as a constructor, so its tag never matched
-- and the pair failed: "No solutions found" instead of True. Found by the
-- KiCS2 benchmark ExpSimpFunPats, whose functional pattern has `?` in it.
data AB = A | B
data W = W AB

main :: Bool
main = W (A ? B) =:<= W B
