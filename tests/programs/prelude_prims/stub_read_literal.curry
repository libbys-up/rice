-- `read`/`reads` on primitive types bottom out in runtime/prelude.c's
-- read*Literal stubs (Prelude__prim_USreadNatLiteral_hnf etc.), each
-- `error("read*Literal not implemented yet", root)`. XFAIL until
-- implemented -- see tests/manifest.txt.
main :: Int
main = read "42"
