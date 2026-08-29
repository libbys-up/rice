module CodeGen where

import Writer
import CodeGen.Options

type CodeGen a = WriterT (DList String) (State (Int, CompileOptions)) a

writeCode :: String -> CompileOptions -> CodeGen () -> IO ()
writeCode file opts code = writeFile file (unlines (genCode opts code))

genCode :: CompileOptions -> CodeGen () -> [String]
genCode opts code = concat $ toList $ snd $ evalState (runWriterT w) (0,opts)

emit :: String -> CodeGen ()
emit line = do (tab,_) <- lift get
               tell (singleton (replicate tab ++ line))

emitAll :: [String] -> CodeGen ()
emitAll lines = do (tab,_) <- lift get
                   tell (fromList $ map (replicate tab) lines)

nl :: CodeGen ()
nl = tell (singleton "")