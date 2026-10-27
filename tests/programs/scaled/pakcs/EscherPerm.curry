-- Scaled-up copy of tests/programs/pakcs_examples/EscherPerm.curry, for optbench.sh's timing:
-- Permutes [1..9] instead of three days (Day has only seven values),
-- keeping only the reversed list, so the golden is one line.

-- From PAKCS's examples (pakcs/examples/EscherPerm.curry), unchanged apart from
-- the main at the end, which runs one of its goals.
-- Module "Permute" from new Escher report:

data Day = Mon | Tue | Wed | Thu | Fri | Sat | Sun

data Person = Mary | Bill | Joe | Fred

permute([] ,l) = l=:=[]
permute(h:t,l) = let r,u,v free in
                 permute(t,r) & split(r,u,v) & l=:=concatenate(u,h:v)

concatenate([] ,x) = x
concatenate(u:x,y) = u:concatenate(x,y)

split([] ,x,y) = x=:=[] & y=:=[]
split(x:y,v,w) = v=:=[] & w=:=x:y
split(x:y,v,w) = let z free in v=:=x:z & split(y,z,w)

splitc(l,x,y) = concatenate(x,y)=:=l

-- Goals:
goal1     = concatenate([Mon,Tue],[Wed])
goal2 x y = split([Mon,Tue],x,y)
goal3 x   = permute([Mon,Tue,Wed],x)

-- Added for rice:
main :: [Int]
main | permute([1..9],x) & x =:= [9,8..1] = x where x free
