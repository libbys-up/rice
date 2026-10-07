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
-- except for =:<<=, (=:=), and (=:<=): kics2's own Prelude.curry (the
-- branch Rice's frontend actually selects -- see its own #else, not
-- #ifdef __PAKCS__) declares these two *without* PAKCS's `Data a =>`
-- constraint, so every call site anywhere already compiles them as plain
-- 2-argument calls. Giving the replacement definitions here PAKCS's
-- constrained signature instead made Rice's dictionary-passing add a real
-- (unused, since the body never references it) 3rd parameter that no call
-- site ever supplies -- reduce/inlineCall's subGrounded zips the callee's
-- 3 renamed parameters against the caller's 2 actual arguments and
-- silently drops the last one instead of erroring on the length
-- mismatch, leaving a dangling reference to a variable nothing binds.
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
