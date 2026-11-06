-- $!! normalizes a million-element list. nf used to recurse one C call
-- per element; on the evaluation machine each pending element is a
-- frame on Rice's own stack.
main :: IO ()
main = print (const 0 $!! [1 .. 1000000 :: Int])
