module replace_Prelude where

-- Rice's own definitions of some Prelude functions. Rice.Files.Replace
-- swaps each one in for the Prelude function of the same name.

aValueNat :: Int -> Int
aValueNat n = n ? -n ? aValueNat (n+1)

-- Value generator for integers.
aValueInt :: Int
aValueInt = 0 ? aValueNat 1

-- Value generator for floats. It is simply implemented by guessing the
-- two parts before and after the point. Could be replaced by other
-- enumeration methods.
--aValueFloat :: Float
--aValueFloat = aValuePosFloat ? 0 ? (0 - aValuePosFloat)
--
---- Value generator for positive floats. It is simply implemented by guessing
---- the two parts before and after the point. Could be replaced by other
---- enumeration methods.
--aValuePosFloat :: Float
--aValuePosFloat = fromInt aValuePosNat + nat2float 0.1 aValuePosNat
-- where
--  -- Transform a natural to float<1, e.g., nat2float 0.1 135 = 0.531
--  nat2float :: Float -> Int -> Float
--  nat2float m i =
--    if i == 0 then 0
--              else nat2float (m / 10) (i `div` 10) + m * fromInt (i `mod` 10)


-- These follow PAKCS's Prelude, except for the types of (=:=) and (=:<=).
-- The front end compiles Prelude's KiCS2 branch, where they have no
-- `Data a =>` constraint, so every call passes two arguments. A replacement
-- has to have the same type as the function it replaces: a constraint here
-- would add a dictionary parameter that no call supplies.
ioError :: IOError -> IO _
ioError err = error (show err)

(=:=) :: a -> a -> Bool
x =:= y = constrEq x y

constrEq :: a -> a -> Bool
constrEq external

(=:<=) :: a -> a -> Bool
x =:<= y = nonstrictEq x y

nonstrictEq :: a -> a -> Bool
nonstrictEq external

(=:<<=) :: Data a => a -> a -> Bool
_ =:<<= _ = error "Prelude.=:<<= not supported!"
