-- Derived Read has to read the escapes any Curry system writes, not just
-- the ones rice's show writes. The front end writes '\DEL' in typed
-- FlatCurry, and rice's read didn't know it, so reading Data.Char's
-- .tfcy went wrong (found bootstrapping: rice1 crashed writing its import
-- list). Also: a byte above 127 in a string came back negative.
main :: IO ()
main = do
  print (map ord (read "['a','\\DEL','\\128','\\255','\\NUL','\\SOH','\\SO','\\^A','\\x41','\\o101','\\SP']" :: [Char]))
  print (map ord (read "\"\\SOH\\SO\\&H\\200\\&5\"" :: String))
