-- Two imported modules whose names end the same way. Their headers were
-- both included as "Util.h", so one module's constructors were undeclared
-- in the C. Found compiling transformers' Control.Monad.Trans.State, which
-- imports Control.Monad.Trans.Class and Control.Monad.IO.Class.
import Lib.One.Util
import Lib.Two.Util

main :: Int
main = one (One 1) + two (Two 2)
