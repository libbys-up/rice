module replace_Prelude where

-- replacements for Prelude that we need for RICE

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


-- Make sure these are all the PAKCS versions
-- except for =:<<=
ioError :: IOError -> IO _
ioError err = error (show err)

(=:=) :: Data a => a -> a -> Bool
x =:= y = constrEq x y

constrEq :: a -> a -> Bool
constrEq external

(=:<=) :: Data a => a -> a -> Bool
x =:<= y = nonstrictEq x y

nonstrictEq :: a -> a -> Bool
nonstrictEq external

(=:<<=) :: Data a => a -> a -> Bool
_ =:<<= _ = error "Prelude.=:<<= not supported!"
