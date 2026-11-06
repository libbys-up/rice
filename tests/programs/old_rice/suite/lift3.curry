

ret x = x

f x = x

g x y = x

run v1 v2 v3 v4 = let v5 = v4 in (ret v2) ((v3 v1) v5)

main = run True f g True
