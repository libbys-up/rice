-- Prelude___AN_hnf (runtime/ext/Prelude.c, backing `&`) called `nf(x)` and
-- then read `x.n->symbol->tag` directly -- broken the same way
-- strictApply's own pre-settle() bug was (see strictapply_forward.curry):
-- `nf` takes its argument *by value*, and internally chases FORWARD_TAG
-- into its own local variable, mutating whatever it settles on in place
-- but never writing that back into the caller's own `x`. If `x`'s own
-- node ends up FORWARD_TAG (extremely common -- e.g. a dictionary-method
-- case whose own result is itself a further call, redirected via
-- set_forward rather than becoming a plain True/False constructor
-- directly, exactly what `/=`'s own dictionary dispatch does), the tag
-- check right after `nf(x)` sees FORWARD_TAG, matching neither FAIL_TAG
-- nor Prelude__False_TAG, and silently falls through to the "must be
-- True" branch -- discarding a real False.
--
-- `chk`'s shape (two independent recursive calls both consuming the
-- same shared tail `cs`, chained via `&`) mirrors kics2's own
-- old_rice/benchmarks/queens_perm.curry's `valid`, where this bug first
-- surfaced: the N-queens filter there silently accepted every
-- permutation (720 "solutions" for 6 elements instead of the correct 4)
-- because `(c /= q) & ...`'s own False was never actually seen once
-- `/=`'s dictionary dispatch left it sitting behind a forward.
--
-- Confirmed via --debug=high: `(1 /= 1)` (the head colliding with `q`)
-- correctly settles to `False` (visible in the trace as "leaving
-- _def#/=#Prelude.Eq_CASE6 / False"), but the very next line shows the
-- enclosing `&` node forwarding to its *second* operand instead of
-- becoming `Prelude__False` -- exactly the bug above.
--
-- Fixed by using settle() (runtime.h) instead of nf()+direct-tag-read,
-- matching strictApply/cond/bindIO/prim_ioError's own established fix
-- for this same class of bug.
chk :: Int -> [Int] -> Bool
chk _  []     = True
chk q (c:cs) = (c /= q) & chk q cs & chk c cs

main :: Bool
main = chk 1 [1,2,3]   -- head (1) collides with q (1) -> must be False
