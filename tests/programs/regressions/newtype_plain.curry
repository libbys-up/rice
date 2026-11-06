-- A newtype with no instances. ICurry generation used to remove the
-- newtype itself, inferring types again after unbox had turned the
-- literal into a boxed Int#, and failed: "types not unifiable: Int#, Int".
-- The front end now removes newtypes (-Odesugar-newtypes).
newtype Box a = Box a

unBox :: Box a -> a
unBox (Box a) = a

main :: Int
main = unBox (Box 41)
