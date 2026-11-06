module Lib.Two.Util where

data Two = Two Int

two :: Two -> Int
two (Two n) = n
