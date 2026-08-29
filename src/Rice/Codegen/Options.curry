module CodeGen.Options where

-- Options for code generator
--  optimize: ???
--  debug: how much debuging info to generate
--  printC: whether to print the generated C code to stdout
--  printH: whether to print the generated header code to stdout
--
-- These three are used for memoized backtracking optimization
-- We want an easy way to turn each of them on and off.
-- I think they're independant, so we can try all combinations.
--  nondetOpt: Optimize with memoized backtracking.
--  callRetOpt: If the statment of the IBlock is a return of a function call,
--              then just do the function call
--              This is similar to tail call optimization, but more stupid.
--              The alternative is setting the node to be the unevaluated thunk, and returning that
--              which will immediately get evaluated int he next pass through the switch loop.
--  backtrackOpt: Optimize by remembering the height of the backtracking stack.
--                If we fail, then start backtracking immediatly instead of propigating the failure to main
--                If we hit a backtracking point, then propigate the failure

data CompileOptions = CompileOptions
 { optimize :: Int
 , debug :: Bool
 , printC :: Bool
 , printH :: Bool
 , nondetOpt :: Bool     -- --memoBT
 , callRetOpt :: Bool    -- --tco
 , backtrackOpt :: Bool  -- --BTguard
 } deriving (Show, Eq)