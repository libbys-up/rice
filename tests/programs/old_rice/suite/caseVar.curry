
f :: Bool -> Bool
f y = let x = True ? False
      in case x of
              True -> True == y
              False -> False == y

main = f True
