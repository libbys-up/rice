-- Exercises every Float-related external primitive replace_Prim.curry
-- declares: plusFloat, minusFloat, timesFloat, divFloat, negateFloat,
-- intToFloat, truncateFloat, roundFloat, eqFloat, ltEqFloat, and the
-- full Floating instance (logFloat/expFloat/sqrtFloat/sin.../asin.../
-- sinh.../asinh...).
main :: [Float]
main =
  [ 3.0 + 4.0         -- plusFloat
  , 10.0 - 3.0        -- minusFloat
  , 6.0 * 7.0         -- timesFloat
  , 7.0 / 2.0         -- divFloat
  , negate 5.0        -- negateFloat
  , fromInt 5         -- intToFloat (fromInt is Prelude's public name for it)
  , fromInt (truncate 3.9)    -- truncateFloat (round-trip, exact: 3.0)
  , fromInt (round 3.5)       -- roundFloat (round-trip: 4.0, round-half-to-even or up)
  , if 3.0 == 3.0 then 1.0 else 0.0   -- eqFloat (True)
  , if 3.0 == 3.1 then 1.0 else 0.0   -- eqFloat (False)
  , if 3.0 <= 3.1 then 1.0 else 0.0   -- ltEqFloat
  , log (exp 1.0)     -- logFloat/expFloat round-trip (~1.0)
  , sqrt 16.0         -- sqrtFloat
  , sin 0.0           -- sinFloat
  , cos 0.0           -- cosFloat
  , tan 0.0           -- tanFloat
  , asin 0.0          -- asinFloat
  , acos 1.0          -- acosFloat
  , atan 0.0          -- atanFloat
  , sinh 0.0          -- sinhFloat
  , cosh 0.0          -- coshFloat
  , tanh 0.0          -- tanhFloat
  , asinh 0.0         -- asinhFloat
  , acosh 1.0         -- acoshFloat
  , atanh 0.0         -- atanhFloat
  ]
