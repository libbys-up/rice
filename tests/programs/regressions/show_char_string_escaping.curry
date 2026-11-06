-- prim_showCharLiteral/prim_showStringLiteral (runtime/ext/Prelude.c) just
-- returned the raw character/string content, with no quoting or
-- escaping at all -- `show 'x'` gave the bare string "x" instead of
-- "'x'", `show "hi"` gave "hi" instead of "\"hi\"". The same gap
-- existed independently in runtime.c's own top-level "print a found
-- solution" path (print_string, and print_final's bare-Char case),
-- which doesn't go through prim_show*Literal at all (only reached when
-- a Curry program calls `show` itself) -- confirmed by diffing raw
-- bytes against real kics2's own output for this exact program.
--
-- Fixed by adding proper derived-Show escaping (ext/Prelude.c's
-- appendEscaped, shared via runtime.h with runtime.c) to all three
-- places: the named escapes GHC's derived Show uses (\a\b\f\n\r\t\v,
-- plus \\ and the enclosing delimiter), decimal \NNN for anything else
-- non-printable, and no escaping for the *other* quote character (a
-- bare '"' is fine inside 'x', a bare '\'' is fine inside "...").
main :: [String]
main = [ show 'a', show '\n', show '\t', show '\\', show '\'', show '"'
       , show "a\nb", show "tab\there", show "back\\slash", show "quo\"te"
       , show "sing'le"
       ]
