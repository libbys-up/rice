-- A functional pattern whose function is a choice. Both alternatives of
-- `pick x` match B (the left by binding x), so there are two answers;
-- rice used to find one (see lazy_unify_choice.curry).
data AB = A | B

pick :: AB -> AB
pick x = x ? B

f :: AB -> Bool
f (pick x) = True

main :: Bool
main = f B
