-- Prelude.cond (backs guards: `f x | c = e` compiles to `f x = cond c e`;
-- also directly callable, since it's exported) had the same bug as
-- strictApply (see debug_repros/strictapply_forward.curry), plus its own
-- second gap: it chased FORWARD_TAG in a loop, but the loop never
-- redispatched with HNF_SETTLE on whatever it chased *to* -- so if
-- chasing landed on a still-unresolved CHOICE_TAG or FUNCTION_TAG, the
-- loop just stopped there, cold, without ever calling choose() on it.
--
-- `False ? True` gets collapsed to a forward by the enclosing let (a
-- fresh choice node is never collapse_safe), so cond's own first
-- argument is that forward, not the raw choice.
--
-- Wrong (bug): "No solutions found" -- neither alternative of the choice
-- was ever actually resolved via choose(), just chased past, so cond
-- fell through to its own `else: fail(root)` on both explorations,
-- including the one where the guard is genuinely True.
-- Correct (fixed): "SOLUTION: 99" -- exactly once, from the True
-- alternative; the False alternative is silently, correctly skipped.
main :: Int
main = cond (False ? True) 99
