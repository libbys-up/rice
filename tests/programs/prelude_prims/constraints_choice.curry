-- Exercises the constraint/choice/strictness family of externals:
-- constrEq (=:=), (&), apply, ($!)/($!!)/($##).
--
-- Deliberately only the "succeeds cleanly" shapes: a *failing* (=:=)
-- or (&) usage isn't reliably comparable against real kics2 here --
-- even kics2's own `:eval` prints an unresolved `!` marker rather than
-- a clean False for e.g. `if True & False then 1 else 0` inside a list
-- like this one, a kics2 REPL display quirk unrelated to whether Rice
-- computes the right thing. `?`/`failed` backtracking (which is what a
-- failing (=:=)/(&) actually behaves like) is exercised properly,
-- unambiguously, in failed_choice.curry instead.
double :: Int -> Int
double x = x * 2

main :: [Int]
main =
  [ if (3 :: Int) =:= 3 then 1 else 0     -- constrEq (True)
  , if True & True  then 1 else 0         -- (&) both True
  , apply double 21                        -- apply, indirect call through a function value
  , (double $! 21)                         -- ($!)
  , (double $!! 21)                        -- ($!!)
  , (double $## 21)                        -- ($##)
  ]
