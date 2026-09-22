data Exp = Exp :+ Exp
         | Exp :- Exp
         | Exp :* Exp
         | Exp :/ Exp
         | Num Int

eval :: Exp -> Int
eval (Num x) = x
eval (x :+ y) = eval x + eval y
eval (x :- y) = eval x - eval y
eval (x :* y) = eval x * eval y
eval (x :/ y) = let cond = x' `mod` y' == 0
                in case y' > 0 && cond of
                        True -> x' `div` y'
 where x' = eval x
       y' = eval y

mkExp2 :: Int -> Int -> Exp
mkExp2 a b = let e1 = Num a
                 e2 = Num b
             in  e1 :+ e2 ?
                 e1 :- e2 ?
                 e1 :* e2 ?
                 e1 :/ e2

main :: Int
main = eval (mkExp2 3 0)
