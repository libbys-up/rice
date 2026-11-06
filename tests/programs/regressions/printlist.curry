-- print_list (runtime.c) read (:)'s two children backwards (the
-- reversed-storage convention codegen itself moved off of during Phase 1
-- -- see docs/history/status-2026-09.md) and had never been exercised by any test whose `main`
-- returns a list directly: it read a raw Int value as a tail pointer and
-- segfaulted on any list with 2+ elements. See tests/programs/regressions/
-- printtuple.curry/printstring.curry for the same bug's other two spots.
main :: [Int]
main = [1,2,3]
