
--- Simple test cases for A-Normal Form transformation.
--- These are example Curry programs that can be parsed and transformed.

module ANFTestExamples where

--- Test: Let binding with simple expression
letTest1 = id (let x = 1 : []
                in x ++ x)

--- Test: Let binding with string concatenation  
letTest2 = id (let x = "hi" ++ "hi"
                in x ++ x)

