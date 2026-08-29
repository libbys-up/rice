module replace_Prim where

-- replacements for Prelude that we need for RICE

import Prelude hiding (Int,Char,Float)

external data Char_SH
data Char = Char Char_SH

external data Int_SH
data Int = Int Int_SH

external data Float_SH
data Float = Float Float_SH

eqChar :: Char -> Char -> Bool
eqChar x y = fcase x of
                   Char x' -> fcase y of
                                    Char y' -> prim_eqChar x' y'

prim_eqChar :: Char_SH -> Char_SH -> Bool
prim_eqChar external

eqInt :: Int -> Int -> Bool
eqInt x y = fcase x of
                  Int x' -> fcase y of
                                  Int y' -> prim_eqInt x' y'

prim_eqInt :: Int_SH -> Int_SH -> Bool
prim_eqInt external

eqFloat :: Float -> Float -> Bool
eqFloat x y = fcase x of
                    Float x' -> fcase y of
                                      Float y' -> prim_eqFloat x' y'

prim_eqFloat :: Float_SH -> Float_SH -> Bool
prim_eqFloat external

ltEqChar :: Char -> Char -> Bool
ltEqChar x y = fcase x of
                     Char x' -> fcase y of
                                      Char y' -> prim_ltEqChar x' y'

prim_ltEqChar :: Char_SH -> Char_SH -> Bool
prim_ltEqChar external

ltEqInt :: Int -> Int -> Bool
ltEqInt x y = fcase x of
                    Int x' -> fcase y of
                                    Int y' -> prim_ltEqInt x' y'

prim_ltEqInt :: Int_SH -> Int_SH -> Bool
prim_ltEqInt external

ltEqFloat :: Float -> Float -> Bool
ltEqFloat x y = fcase x of
                      Float x' -> fcase y of
                                        Float y' -> prim_ltEqFloat x' y'

prim_ltEqFloat :: Float_SH -> Float_SH -> Bool
prim_ltEqFloat external

showCharLiteral :: Char -> String
showCharLiteral x = fcase x of 
                          Char x' -> prim_showCharLiteral x'

prim_showCharLiteral :: Char_SH -> String
prim_showCharLiteral external

showIntLiteral :: Int -> String
showIntLiteral x = fcase x of
                         Int x' -> prim_showIntLiteral x'

prim_showIntLiteral :: Int_SH -> String
prim_showIntLiteral external

showFloatLiteral :: Float -> String
showFloatLiteral x = fcase x of
                           Float x' -> prim_showFloatLiteral x'

prim_showFloatLiteral :: Float_SH -> String
prim_showFloatLiteral external

plusInt :: Int -> Int -> Int
plusInt x y = fcase x of
                    Int x' -> fcase y of 
                                    Int y' -> Int (prim_plusInt x' y')

prim_plusInt :: Int_SH -> Int_SH -> Int_SH
prim_plusInt external

minusInt :: Int -> Int -> Int
minusInt x y = fcase x of
                     Int x' -> fcase y of 
                                     Int y' -> Int (prim_minusInt x' y')

prim_minusInt :: Int_SH -> Int_SH -> Int_SH
prim_minusInt external

timesInt :: Int -> Int -> Int
timesInt x y = fcase x of
                     Int x' -> fcase y of 
                                     Int y' -> Int (prim_timesInt x' y')

prim_timesInt :: Int_SH -> Int_SH -> Int_SH
prim_timesInt external

plusFloat :: Float -> Float -> Float
plusFloat x y = fcase x of
                      Float x' -> fcase y of 
                                        Float y' -> Float (prim_plusFloat x' y')

prim_plusFloat :: Float_SH -> Float_SH -> Float_SH
prim_plusFloat external

minusFloat :: Float -> Float -> Float
minusFloat x y = fcase x of
                       Float x' -> fcase y of 
                                         Float y' -> Float (prim_minusFloat x' y')

prim_minusFloat :: Float_SH -> Float_SH -> Float_SH
prim_minusFloat external

timesFloat :: Float -> Float -> Float
timesFloat x y = fcase x of
                       Float x' -> fcase y of 
                                         Float y' -> Float (prim_timesFloat x' y')

prim_timesFloat :: Float_SH -> Float_SH -> Float_SH
prim_timesFloat external

negateFloat :: Float -> Float
negateFloat x = fcase x of
                      Float x' -> Float (prim_negateFloat x')

prim_negateFloat :: Float_SH -> Float_SH
prim_negateFloat external

intToFloat :: Int -> Float
intToFloat x = fcase x of
                     Int x' -> Float (prim_intToFloat x')

prim_intToFloat :: Int_SH -> Float_SH
prim_intToFloat external

divFloat :: Float -> Float -> Float
divFloat x y = fcase x of
                     Float x' -> fcase y of 
                                       Float y' -> Float (prim_divFloat x' y')

prim_divFloat :: Float_SH -> Float_SH -> Float_SH
prim_divFloat external

divInt :: Int -> Int -> Int
divInt x y = fcase x of
                   Int x' -> fcase y of 
                                   Int y' -> Int (prim_divInt x' y')

prim_divInt :: Int_SH -> Int_SH -> Int_SH
prim_divInt external

modInt :: Int -> Int -> Int
modInt x y = fcase x of
                   Int x' -> fcase y of 
                                   Int y' -> Int (prim_modInt x' y')

prim_modInt :: Int_SH -> Int_SH -> Int_SH
prim_modInt external

quotInt :: Int -> Int -> Int
quotInt x y = fcase x of
                    Int x' -> fcase y of 
                                    Int y' -> Int (prim_quotInt x' y')

prim_quotInt :: Int_SH -> Int_SH -> Int_SH
prim_quotInt external

remInt :: Int -> Int -> Int
remInt x y = fcase x of
                   Int x' -> fcase y of 
                                   Int y' -> Int (prim_remInt x' y')

prim_remInt :: Int_SH -> Int_SH -> Int_SH
prim_remInt external

truncateFloat :: Float -> Int
truncateFloat x = fcase x of
                        Float x' -> Int (prim_truncateFloat x')

prim_truncateFloat :: Float_SH -> Int_SH
prim_truncateFloat external

roundFloat :: Float -> Int
roundFloat x = fcase x of
                    Float x' -> Int (prim_roundFloat x')

prim_roundFloat :: Float_SH -> Int_SH
prim_roundFloat external

logFloat :: Float -> Float
logFloat x = fcase x of
                   Float x' -> Float (prim_logFloat x')

prim_logFloat :: Float_SH -> Float_SH
prim_logFloat external

expFloat :: Float -> Float
expFloat x = fcase x of
                   Float x' -> Float (prim_expFloat x')

prim_expFloat :: Float_SH -> Float_SH
prim_expFloat external

sqrtFloat :: Float -> Float
sqrtFloat x = fcase x of
                    Float x' -> Float (prim_sqrtFloat x')

prim_sqrtFloat :: Float_SH -> Float_SH
prim_sqrtFloat external

sinFloat :: Float -> Float
sinFloat x = fcase x of
                    Float x' -> Float (prim_sinFloat x')

prim_sinFloat :: Float_SH -> Float_SH
prim_sinFloat external

cosFloat :: Float -> Float
cosFloat x = fcase x of
                    Float x' -> Float (prim_sinFloat x')

prim_cosFloat :: Float_SH -> Float_SH
prim_cosFloat external

tanFloat :: Float -> Float
tanFloat x = fcase x of
                    Float x' -> Float (prim_tanFloat x')

prim_tanFloat :: Float_SH -> Float_SH
prim_tanFloat external

asinFloat :: Float -> Float
asinFloat x = fcase x of
                    Float x' -> Float (prim_asinFloat x')

prim_asinFloat :: Float_SH -> Float_SH
prim_asinFloat external

acosFloat :: Float -> Float
acosFloat x = fcase x of
                    Float x' -> Float (prim_acosFloat x')

prim_acosFloat :: Float_SH -> Float_SH
prim_acosFloat external

atanFloat :: Float -> Float
atanFloat x = fcase x of
                    Float x' -> Float (prim_atanFloat x')

prim_atanFloat :: Float_SH -> Float_SH
prim_atanFloat external

sinhFloat :: Float -> Float
sinhFloat x = fcase x of
                    Float x' -> Float (prim_sinhFloat x')

prim_sinhFloat :: Float_SH -> Float_SH
prim_sinhFloat external

coshFloat :: Float -> Float
coshFloat x = fcase x of
                    Float x' -> Float (prim_coshFloat x')

prim_coshFloat :: Float_SH -> Float_SH
prim_coshFloat external

tanhFloat :: Float -> Float
tanhFloat x = fcase x of
                    Float x' -> Float (prim_tanhFloat x')

prim_tanhFloat :: Float_SH -> Float_SH
prim_tanhFloat external

asinhFloat :: Float -> Float
asinhFloat x = fcase x of
                     Float x' -> Float (prim_asinhFloat x')

prim_asinhFloat :: Float_SH -> Float_SH
prim_asinhFloat external

acoshFloat :: Float -> Float
acoshFloat x = fcase x of
                     Float x' -> Float (prim_acoshFloat x')

prim_acoshFloat :: Float_SH -> Float_SH
prim_acoshFloat external

atanhFloat :: Float -> Float
atanhFloat x = fcase x of
                     Float x' -> Float (prim_atanhFloat x')

prim_atanhFloat :: Float_SH -> Float_SH
prim_atanhFloat external

ord :: Char -> Int
ord c = fcase c of
              Char c' -> Int (prim_ord c')

prim_ord :: Char_SH -> Int_SH
prim_ord external

-- n < 0 returns 0
-- n > 1114111 returns 1114111
chr :: Int -> Char
chr n = fcase n of
              Int n' -> Char (prim_chr n')

prim_chr :: Int_SH -> Char_SH
prim_chr external

putChar :: Char -> IO ()
putChar c = fcase c of
                  Char c' -> prim_putChar c'

prim_putChar :: Char_SH -> IO ()
prim_putChar external

