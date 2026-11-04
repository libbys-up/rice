------------------------------------------------------------------------------
--- `ReadWrite` instances (package rw-data) for typed FlatCurry, so the
--- caches can be written in rw-data's compact format instead of with
--- `show` and read back with derived `read` (`Rice.Build.Cache`).
---
--- The `FlatCurry.Types` instances come with flatcurry (`FlatCurry.TypesRW`);
--- the typed ones don't, so they're here. They follow `curry-rw-data`'s
--- generated code: a constructor is its index as one character (only for
--- types with more than one constructor), then its fields in order.
--- If `FlatCurry.Typed.Types` changes, change these to match.
---
--- @author Steven Libby
------------------------------------------------------------------------------

{-# OPTIONS_FRONTEND -Wno-incomplete-patterns #-}

module Rice.Build.TypedRW where

import FlatCurry.Types
import FlatCurry.TypesRW ()
import FlatCurry.Typed.Types hiding (typeOf)
import RW.Base
import System.IO (hPutChar)

instance ReadWrite TProg where
  readRW strs r0 = (TProg a' b' c' d' e',r5)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1
      (c',r3) = readRW strs r2
      (d',r4) = readRW strs r3
      (e',r5) = readRW strs r4

  showRW params strs0 (TProg a' b' c' d' e') =
    (strs5,(show1 . show2 . show3 . show4 . show5))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'
      (strs3,show3) = showRW params strs2 c'
      (strs4,show4) = showRW params strs3 d'
      (strs5,show5) = showRW params strs4 e'

  writeRW params h (TProg a' b' c' d' e') strs =
    writeRW params h a' strs
      >>= writeRW params h b'
      >>= writeRW params h c'
      >>= writeRW params h d'
      >>= writeRW params h e'

  typeOf _ = monoRWType "TProg"

instance ReadWrite TFuncDecl where
  readRW strs r0 = (TFunc a' b' c' d' e',r5)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1
      (c',r3) = readRW strs r2
      (d',r4) = readRW strs r3
      (e',r5) = readRW strs r4

  showRW params strs0 (TFunc a' b' c' d' e') =
    (strs5,(show1 . show2 . show3 . show4 . show5))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'
      (strs3,show3) = showRW params strs2 c'
      (strs4,show4) = showRW params strs3 d'
      (strs5,show5) = showRW params strs4 e'

  writeRW params h (TFunc a' b' c' d' e') strs =
    writeRW params h a' strs
      >>= writeRW params h b'
      >>= writeRW params h c'
      >>= writeRW params h d'
      >>= writeRW params h e'

  typeOf _ = monoRWType "TFuncDecl"

instance ReadWrite TRule where
  readRW strs ('0' : r0) = (TRule a' b',r2)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1
  readRW strs ('1' : r0) = (TExternal a' b',r2)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1

  showRW params strs0 (TRule a' b') = (strs2,showChar '0' . (show1 . show2))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'
  showRW params strs0 (TExternal a' b') =
    (strs2,showChar '1' . (show1 . show2))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'

  writeRW params h (TRule a' b') strs =
    hPutChar h '0' >> (writeRW params h a' strs
      >>= writeRW params h b')
  writeRW params h (TExternal a' b') strs =
    hPutChar h '1' >> (writeRW params h a' strs
      >>= writeRW params h b')

  typeOf _ = monoRWType "TRule"

instance ReadWrite TExpr where
  readRW strs ('0' : r0) = (TVarE a' b',r2)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1
  readRW strs ('1' : r0) = (TLit a' b',r2)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1
  readRW strs ('2' : r0) = (TComb a' b' c' d',r4)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1
      (c',r3) = readRW strs r2
      (d',r4) = readRW strs r3
  readRW strs ('3' : r0) = (TLet a' b',r2)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1
  readRW strs ('4' : r0) = (TFree a' b',r2)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1
  readRW strs ('5' : r0) = (TOr a' b',r2)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1
  readRW strs ('6' : r0) = (TCase a' b' c',r3)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1
      (c',r3) = readRW strs r2
  readRW strs ('7' : r0) = (TTyped a' b',r2)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1

  showRW params strs0 (TVarE a' b') = (strs2,showChar '0' . (show1 . show2))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'
  showRW params strs0 (TLit a' b') = (strs2,showChar '1' . (show1 . show2))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'
  showRW params strs0 (TComb a' b' c' d') =
    (strs4,showChar '2' . (show1 . show2 . show3 . show4))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'
      (strs3,show3) = showRW params strs2 c'
      (strs4,show4) = showRW params strs3 d'
  showRW params strs0 (TLet a' b') = (strs2,showChar '3' . (show1 . show2))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'
  showRW params strs0 (TFree a' b') = (strs2,showChar '4' . (show1 . show2))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'
  showRW params strs0 (TOr a' b') = (strs2,showChar '5' . (show1 . show2))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'
  showRW params strs0 (TCase a' b' c') =
    (strs3,showChar '6' . (show1 . show2 . show3))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'
      (strs3,show3) = showRW params strs2 c'
  showRW params strs0 (TTyped a' b') = (strs2,showChar '7' . (show1 . show2))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'

  writeRW params h (TVarE a' b') strs =
    hPutChar h '0' >> (writeRW params h a' strs
      >>= writeRW params h b')
  writeRW params h (TLit a' b') strs =
    hPutChar h '1' >> (writeRW params h a' strs
      >>= writeRW params h b')
  writeRW params h (TComb a' b' c' d') strs =
    hPutChar h '2' >> (writeRW params h a' strs
      >>= writeRW params h b'
      >>= writeRW params h c'
      >>= writeRW params h d')
  writeRW params h (TLet a' b') strs =
    hPutChar h '3' >> (writeRW params h a' strs
      >>= writeRW params h b')
  writeRW params h (TFree a' b') strs =
    hPutChar h '4' >> (writeRW params h a' strs
      >>= writeRW params h b')
  writeRW params h (TOr a' b') strs =
    hPutChar h '5' >> (writeRW params h a' strs
      >>= writeRW params h b')
  writeRW params h (TCase a' b' c') strs =
    hPutChar h '6' >> (writeRW params h a' strs
      >>= writeRW params h b'
      >>= writeRW params h c')
  writeRW params h (TTyped a' b') strs =
    hPutChar h '7' >> (writeRW params h a' strs
      >>= writeRW params h b')

  typeOf _ = monoRWType "TExpr"

instance ReadWrite TBranchExpr where
  readRW strs r0 = (TBranch a' b',r2)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1

  showRW params strs0 (TBranch a' b') = (strs2,(show1 . show2))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'

  writeRW params h (TBranch a' b') strs =
    writeRW params h a' strs
      >>= writeRW params h b'

  typeOf _ = monoRWType "TBranchExpr"

instance ReadWrite TPattern where
  readRW strs ('0' : r0) = (TPattern a' b' c',r3)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1
      (c',r3) = readRW strs r2
  readRW strs ('1' : r0) = (TLPattern a' b',r2)
    where
      (a',r1) = readRW strs r0
      (b',r2) = readRW strs r1

  showRW params strs0 (TPattern a' b' c') =
    (strs3,showChar '0' . (show1 . show2 . show3))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'
      (strs3,show3) = showRW params strs2 c'
  showRW params strs0 (TLPattern a' b') =
    (strs2,showChar '1' . (show1 . show2))
    where
      (strs1,show1) = showRW params strs0 a'
      (strs2,show2) = showRW params strs1 b'

  writeRW params h (TPattern a' b' c') strs =
    hPutChar h '0' >> (writeRW params h a' strs
      >>= writeRW params h b'
      >>= writeRW params h c')
  writeRW params h (TLPattern a' b') strs =
    hPutChar h '1' >> (writeRW params h a' strs
      >>= writeRW params h b')

  typeOf _ = monoRWType "TPattern"
