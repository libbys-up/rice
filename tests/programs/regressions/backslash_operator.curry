-- An operator whose name ends in a backslash. The comment rice writes
-- above its C function, `// +\`, continued onto the function's first line,
-- and the C didn't compile. Found compiling Data.List's (\\).
infixl 6 +\

(+\) :: Int -> Int -> Int
x +\ y = x - y

main :: Int
main = 5 +\ 2
