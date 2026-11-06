module Lib.One.Util where

data One = One Int

one :: One -> Int
one (One n) = n
