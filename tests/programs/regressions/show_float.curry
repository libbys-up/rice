-- show on Float must be Haskell's (and KiCS2's): the shortest digits that
-- read back exactly, in decimal from 0.1 to 10^7 and scientific outside.
-- It was C's %f ("0.100000"), and since generated C writes float literals
-- with show, a self-compiled rice wrote every Prelude float constant with
-- six decimals. Found by the bootstrap triple test (rice0 vs rice1's C).
main :: IO ()
main = mapM_ print [0.1, 3.5, 7.0, -5.0, 0.0, 1.0e-2, 1.0e7, 9999999.0, 12345.678, 1.0e-10, 0.30000000000000004, 1/3, 2.5e-3, 123456789.0, -0.5, 100.0, 1.0e22]
