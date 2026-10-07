-- From ~/curry/papers/unif/proofs/counterexamples/StaleCase.curry. An old shared
-- thunk `o` is rewritten deterministically after a choice point, to point
-- at a young node whose value depends on that choice. Wrong under #1+#5
-- (opt_conflict.md), and under #5 alone until generated code trailed
-- root writes outside case branches (ToC.curry's uncaseTrail). Run it
-- under RICE_CFLAGS="-DOPT_NONDET_TRAIL=0 -DOPT_EPOCH_TRAIL=1" too.
-- Correct answers checked with PAKCS.
data N = Z | S N

neg :: Bool -> Bool
neg True  = False
neg False = True

mk :: N -> Bool -> Maybe Bool
mk Z     y = Just (neg y)
mk (S n) y = mk n y

unJust :: Maybe a -> a
unJust (Just v) = v

main :: (Bool, Bool)
main = let x = True ? False
           o = mk (S (S (S Z))) x
       in (unJust o, x)
