-- Rice.Transform.ANF's `anf (TTyped e t) k = flip TTyped t <$> (anf e
-- k)` wrapped the *entire* rest of the computation (anf's CPS `k`
-- includes whatever comes after `e`, not just e's own result) in the
-- type annotation, not just `e`'s own value -- wrong for a type
-- annotation specifically (unlike TFree just above it in the same
-- file, where wrapping the whole downstream result *is* correct: a
-- free variable's own scope genuinely needs to extend that far).
--
-- Surfaces on an explicitly type-annotated literal argument to a
-- *primitive* call (constrEq/(=:=) here -- unlike a case scrutinee,
-- Rice.Optimize.Inline.caseCancel's own TTyped fix just above doesn't
-- apply; ANF itself has to outline this into a fresh Let), again as a
-- flat-out C compile failure ("use of undeclared identifier") from the
-- resulting mis-scoped Let.
--
-- Fixed to `anf (TTyped e t) k = anf e (\v -> k (TTyped v t))`: wrap
-- only e's own resulting value, then hand that to k.
main :: Int
main = if (3 :: Int) =:= 3 then 1 else 0
