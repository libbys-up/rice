-- print_string (runtime.c) had the same reversed-child-storage bug as
-- print_list, *and* a separate, independent one: its own "is this a
-- string" check in print_final compared a list's head element's
-- constructor name against "char" (lowercase), which was never a real
-- constructor name under either the old or new storage convention --
-- the real one is "Char" (Prelude's own boxed constructor -- see
-- runtime/prelude.c's toCurryString, which every String literal actually
-- builds through at runtime, via setCurryString/condenseStrings). Neither
-- half of this had ever been exercised by a test whose `main` returns a
-- String directly (see printlist.curry).
main :: String
main = "hi"
