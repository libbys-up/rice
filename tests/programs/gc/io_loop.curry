-- A long IO loop with a constant live set. Each step's bindIO node ends
-- up forwarding to the next step's, so the program's root heads a
-- forwarding chain one link per step; the collector has to skip those
-- links (gc.c's trace_child), or the chain keeps every step alive
-- (927 MB for this loop before it did). Without collection at all this
-- needs gigabytes.
--
-- Why the chain forms: `m >> k` is `m >>= \_ -> k`. Running that bindIO
-- node rewrites it to `apply (\_ -> k) m`, and the lambda returns k, a
-- node that already exists, so the bind node collapses to FORWARD k. Then
-- k, `(loop $! acc') (n - 1)`, is reduced in place into the next step's
-- bindIO node, which later forwards to the next k, and so on. run_io holds
-- the first node for the whole run. Nothing here is special to IO: any
-- long-lived root plus "return a node that already exists" makes a chain.
-- rice-maxrss: 150
loop :: Int -> Int -> IO ()
loop acc n = if n == 0 then print acc
                       else return () >> (loop $! (acc + n `mod` 7)) (n - 1)

main :: IO ()
main = loop 0 5000000
