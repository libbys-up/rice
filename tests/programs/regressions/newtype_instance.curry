-- A newtype with a Functor instance. The instance method's type is a
-- ForallType, which ICurry generation's newtype removal (FlatCurry.AddTypes)
-- can't unify: "unifyTExps: types not unifiable". Found compiling
-- Data.Functor.Identity, the first newtype in rice's own import closure.
newtype Box a = Box a

instance Functor Box where
  fmap f (Box a) = Box (f a)

unBox :: Box a -> a
unBox (Box a) = a

main :: Int
main = unBox (fmap (+1) (Box 41))
