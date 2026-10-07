-- Smoke test for a --debug=high build, which also turns on CHECK_LAYOUT
-- (every node built is checked against its symbol's field reps) and the
-- field-rep lint. The trace prints nodes with raw children
-- (prim_putChar('k'), Float(2.500000)) through print_expr, which used to
-- guess raw-vs-pointer from the value instead of reading the symbol's
-- reps. Only the exit status is checked: the trace itself changes with
-- any codegen change.
-- rice-flags: --debug=high
-- rice-golden: none
main :: IO ()
main = do putStrLn (show 2.5)
          putChar 'k'
          putChar '\n'
