------------------------------------------------------------------------------
--- Turning ICurry names into C identifiers and string literals, shared by
--- `Rice.Codegen.C.*`.
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

-- The name without its module, for debugging output. It isn't unique.
toName :: IQName -> String
toName (_,f,_) = f

--- The C identifier for an ICurry name: `Module__name`, each part mangled.
--- A `_` in either part becomes `_US`, so the `__` separator is unambiguous.
mangle :: IQName -> String
mangle (q,n,_) = nameMangle q ++ "__" ++ nameMangle n

--- Mangles every character of a string.
nameMangle :: String -> String
nameMangle = concatMap mangleChar

--- Letters and digits stay as they are. Every other character becomes `_`
--- followed by a code: two letters for the common operator characters, or
--- `X` and the character's code point for anything else (KiCS2's names for
--- missing instance methods contain spaces and backquotes, for example).
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
                         | otherwise    -> "_X" ++ show (ord c)

--- A readable description of a name, for comments in the generated code.
--- The front end's names for instances, method implementations and
--- defaults (`_inst#...`, `_impl#...`, `_def#...`) are spelled out.
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
-- String constants
-------------------------------------------------------

--- Is this a string literal? `Rice.Transform.StrLit` turns a literal
--- string into a constructor whose module is empty and whose name is the
--- string itself.
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

