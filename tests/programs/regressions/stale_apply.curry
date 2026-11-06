-- From ~/curry/papers/unif/proofs/counterexamples/StaleApply.curry. An old shared
-- thunk `o` is rewritten deterministically after a choice point, to point
-- at a young node whose value depends on that choice. Wrong under #1+#5
-- (developer's manual, "Soundness rules"), and under #5 alone until generated code trailed
-- root writes outside case branches (ToC.curry's uncaseTrail). Run it
-- under RICE_CFLAGS="-DOPT_NONDET_TRAIL=0 -DOPT_EPOCH_TRAIL=1" too.
-- Correct answers checked with PAKCS.
data N = Z | S N

neg :: Bool -> Bool
neg True  = False
neg False = True

idB :: Bool -> Bool
idB b = b

pick :: Bool -> (Bool -> Bool)
pick True  = neg
pick False = idB

mk :: N -> (Bool -> Bool) -> Maybe Bool
mk Z     f = Just (f True)
mk (S n) f = mk n f

unJust :: Maybe a -> a
unJust (Just v) = v

main :: (Bool, Bool)
main = let x = True ? False
           o = mk (S (S (S Z))) (pick x)
       in (unJust o, x)
