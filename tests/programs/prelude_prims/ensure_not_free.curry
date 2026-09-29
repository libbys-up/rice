-- ensureNotFree is a real, exported Prelude function ($# is defined
-- directly in terms of it: `f $# x = f $! (ensureNotFree x)`), but
-- runtime/prelude.c's Prelude__ensureNotFree_hnf is still just
-- `error("ensureNotFree not implemented yet", root)`. XFAIL until
-- that's implemented -- see tests/manifest.txt.
main :: Int
main = ensureNotFree (5 :: Int)
