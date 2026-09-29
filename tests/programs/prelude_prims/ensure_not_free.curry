-- ensureNotFree is a real, exported Prelude function ($# is defined
-- directly in terms of it: `f $# x = f $! (ensureNotFree x)`).
-- runtime/prelude.c's Prelude__ensureNotFree_hnf now settles its
-- argument (chasing FORWARD_TAG, redispatching through
-- FUNCTION_TAG/CHOICE_TAG) and returns it unchanged -- correct for
-- everything except a genuinely-still-unbound free variable, which
-- real kics2 would narrow but this can't (no type information reaches
-- a generic runtime primitive like this one -- see the function's own
-- comment). Not exercised here: this repro (an already-ground Int) is
-- exactly the common case that gap doesn't affect.
main :: Int
main = ensureNotFree (5 :: Int)
