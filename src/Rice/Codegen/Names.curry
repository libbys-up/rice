------------------------------------------------------------------------------
--- Name mangling and small display helpers shared by `Rice.Codegen.C.*`.
--- Ported from old_rice's `Compile.IUtil` (the naming logic itself is
--- correct there and unchanged here) -- this file's own module header used
--- to say `CodeGen.Names`, not matching its path (`Rice/Codegen/Names.
--- curry`), the exact `Rice/Codegen/` naming inconsistency `STYLE_GUIDE.md`
--- already flags; fixed here as part of the Phase 1 port.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module Rice.Codegen.Names (getTag, toName, mangle, uninstance,
                      quote, strConst, isStrConst) where

import Data.List (isPrefixOf, splitOn)
import Data.Char (ord, isAlphaNum)
import ICurry.Types (IQName)

----------------------------------------------------
-- Name mangling
----------------------------------------------------

getTag :: IQName -> Int
getTag (_,_,t) = t

-- It's easier to read debugging information without the module names.
-- but this is technically wrong.
toName :: IQName -> String
toName (_,f,_) = f

--- mangle a name from ICurry.
--- Since _ is a special character that a programmer can use,
--- we double it, since individual _ will get translated to _US
mangle :: IQName -> String
mangle (q,n,_) = nameMangle q ++ "__" ++ nameMangle n

--- mangle an entire string
nameMangle :: String -> String
nameMangle = concatMap mangleChar

--- We need to replace special characters with something that is unique
--- Our rule is that any special character will start with an _
--- and be followed by a 2 letter code.
--- Then the _ will be _US, so it's still unique.
mangleChar :: Char -> String
mangleChar c = case c of
                    '('  -> "_LP"
                    ')'  -> "_RP"
                    '['  -> "_LB"
                    ']'  -> "_RB"
                    ','  -> "_CM"
                    '\'' -> "_SQ"
                    '_'  -> "_US"
                    '~'  -> "_TI"
                    '!'  -> "_EX"
                    '@'  -> "_AT"
                    '#'  -> "_HT"
                    '$'  -> "_DL"
                    '%'  -> "_PC"
                    '^'  -> "_CA"
                    '&'  -> "_AN"
                    '*'  -> "_ST"
                    '+'  -> "_PL"
                    '-'  -> "_MI"
                    '='  -> "_EQ"
                    '<'  -> "_LT"
                    '>'  -> "_GT"
                    ':'  -> "_CO"
                    '?'  -> "_QU"
                    '.'  -> "_DO"
                    '/'  -> "_FS"
                    '\\' -> "_BS"
                    '|'  -> "_OR"
                    _    | isAlphaNum c -> [c]
                         -- Catch-all for anything not in the enumerated
                         -- list above (and not already handled by '_') --
                         -- confirmed necessary empirically, not just
                         -- theoretical: kics2's own generated "no
                         -- instance or default method for class
                         -- operation `...'" placeholder names contain
                         -- spaces and backticks, neither of which the
                         -- original enumerated list anticipated, and
                         -- both fatal to leave unescaped in a C
                         -- identifier.
                         | otherwise    -> "_X" ++ show (ord c)



-- instances, implementations, and defaults for typeclasses
-- already have mangled names.
-- It's helpful for debugging if I can put the origonal information
-- in the comments of generated code.
uninstance :: IQName -> String
uninstance (_,n,_)
 | isPrefixOf "_inst" n = "instance of " ++ unclass (ps!!1) ++ 
                          " for " ++ unclass (ps!!2)
 | isPrefixOf "_impl" n = "implementation of " ++ (ps!!1) ++ 
                          " in " ++ unclass (ps!!2) ++ 
                          " for " ++ unclass (ps!!3)
 | isPrefixOf "_def" n  = "default for " ++ unclass (ps!!1) ++ 
                          " in " ++ unclass (ps!!2)
 | otherwise            = n
  where ps = splitOn "#" n
        unclass s
         | '.' `elem` s = tail (dropWhile (/='.') s)
         | otherwise    = s

-------------------------------------------------------
-- handling string constants and escape characters
--
-- This was used in the optimizer to avoid trying to optimize
-- a large linked list of characters.
-------------------------------------------------------

--- Confirmed against `Rice.Transform.StrLit.condenseStrings`'s own,
--- already-working convention (`TComb t c ("",getString f) []` -- an
--- *empty* module string, the condensed string's own text as the name),
--- not old_rice's assumed `m == "StringConst"`, which never actually
--- matched anything Rice itself generates -- found empirically (a real
--- program's `show`, which relies on exactly this path, produced
--- `make___True` instead of a string-constant call).
isStrConst :: IQName -> Bool
isStrConst (m,_,_) = null m

quote :: String -> String
quote str = "\"" ++ str ++ "\""

strConst :: IQName -> String
strConst (_,n,_) = quote (escape n)

escape :: String -> String
escape = concatMap escChr

escChr :: Char -> String
escChr c = case c of
                '"'  -> "\\\""
                '\'' -> "\\\'"
                '\\' -> "\\\\"
                '\n' -> "\\n"
                '\r' -> "\\r"
                '\t' -> "\\t"
                '\f' -> "\\f"
                '\v' -> "\\v"
                _    -> if ord c > 255 then "?" else [c]

