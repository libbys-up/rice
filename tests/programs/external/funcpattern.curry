-- Non-strict equational constraint / narrowing, in the spirit of kics2's
-- own testsuite/SpecialTests/TestUnification.curry -- exercises (=:<=)
-- directly (see docs/history/status-2026-09.md's "Phase 2, item 2" write-up on the real bug
-- this once hit) via the same last-element idiom old_rice's own
-- last.curry/lastEq.curry use, just at a size small enough to run in the
-- default (non---slow) pass. Monomorphic on Int (matching old_rice's own
-- half.curry, another free-variable-narrowing test) rather than the
-- polymorphic `Data a =>` version -- kics2's own frontend errors out
-- (`List data with no ground term`, from its generated Haskell) on the
-- polymorphic form, a pre-existing frontend limitation, not a Rice bug.

(+-+) :: [Int] -> [Int] -> [Int]
[]     +-+ ys = ys
(x:xs) +-+ ys = x : (xs +-+ ys)

lastOf :: [Int] -> Int
lastOf ys | (xs +-+ [x]) =:<= ys = x
  where xs, x free

main :: Int
main = lastOf [1,2,3,4,5]
