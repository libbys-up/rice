-- A deep, genuinely tail-recursive benchmark: ten million iterations
-- that must run in constant C stack (every tail call, including the
-- one through `$!`, is a musttail jump on the evaluation machine). None
-- of old_rice's own SLOW-tagged benchmarks recurse this way (they're
-- combinatorial-search/large-data-structure heavy, not deep-tail-call
-- heavy).
--
-- Two things this file went through, both worth leaving documented
-- rather than silently fixed, since they're easy to hit again:
--
-- 1. Uses a `case`, not parallel equations, for the base/recursive
--    split -- see STYLE_GUIDE.md's "Pattern matching: flexible
--    equations vs. rigid case" for why a literal-vs-variable equation
--    pair here would recurse forever instead of terminating.
--
-- 2. `$!` on the accumulator (`sumTail $! (acc + n)`), not just
--    `sumTail (acc + n) (n - 1)`. A `case`/rigid match guarantees the
--    *value*, once forced, is correct -- it says nothing about *when*
--    it's forced. Without `$!`, `acc + n` stays an unevaluated thunk,
--    and each call nests another one inside it; forcing the whole
--    chain at the very end needs genuine non-tail recursion (one C
--    stack frame per nested thunk, before the evaluation machine)
--    regardless of anything about sumTail's own tail-call dispatch.
--    `$!` forces the addition *before* building the next call, so the
--    accumulator never accumulates a thunk chain in the first place.
sumTail :: Int -> Int -> Int
sumTail acc n = case n of
  0 -> acc
  _ -> (sumTail $! (acc + n)) (n - 1)

main :: Int
main = sumTail 0 10000000
