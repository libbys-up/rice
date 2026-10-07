module Rice.Transform.StrLit (condenseStrings) where

import FlatCurry.Typed.Types
import FlatCurry.Typed.Goodies (updTProgTExps)

condenseStrings :: TProg -> TProg
condenseStrings = updTProgTExps condense

condense :: TExpr -> TExpr
condense (TVarE t v)         = TVarE t v 
condense (TLit t l)          = TLit t l
condense f@(TComb t c q es)
 | isString f True = TComb t c ("",getString f) []
 | otherwise       = TComb t c q (map condense es)
condense (TLet vs e)         = TLet (map fixLet vs) (condense e)
 where fixLet ((v,t),e) = ((v,t), condense e)
condense (TFree vs e)        = TFree vs (condense e)
condense (TOr e1 e2)         = TOr (condense e1) (condense e2)
condense (TCase ct e bs)     = TCase ct (condense e) (map (\(TBranch p e) -> TBranch p (condense e)) bs)
condense (TTyped e t)        = TTyped (condense e) t

-- check to see if our expression is really a literal string.
-- The empty parameter is to avoid us matching an empty list by itself.
-- It has to be part of a string literal.
isString :: TExpr -> Bool -> Bool
isString c empty = case c of
    TComb _ ConsCall ("Prelude","[]") []     -> not empty
    TComb _ ConsCall ("Prelude",":") [h, t]  -> isChar h && isString t False
    _                                        -> False

isChar :: TExpr -> Bool
isChar c = case c of
    TLit _ (Charc _) -> True
    _                -> False

getString :: TExpr -> String
getString (TComb _ ConsCall ("Prelude","[]") [])     = ""
getString (TComb _ ConsCall ("Prelude",":")  [h, t]) = char h : getString t
 where char (TLit _ (Charc c)) = c
