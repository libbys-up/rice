-- Narrowing a free variable to a box (Prelude's Int) used to write a
-- free-variable pointer into the box's raw slot. Rice has no literal-case
-- narrowing, so it now stops with an error instead. (KiCS2 narrows or
-- suspends here; this test pins down that Rice fails cleanly, not that
-- the error is the final behavior.)
-- rice-exit: 1
f :: Int -> Int
f x = x + 1

main :: Int
main = f x where x free
