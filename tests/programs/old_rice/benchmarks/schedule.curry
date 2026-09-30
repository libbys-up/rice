-- Reduced from the original 5 groups (24 students total, scheduled into
-- 5 test slots) after its golden ballooned to 12MB (72288 solutions), a
-- repo-bloat hazard rather than a cheap/contained cost like this
-- directory's other SLOW entries.
--
-- group1+group2 only (12 students, 3 test slots -- group3/4/5 kept
-- below, commented out, same convention this file already used for
-- theClass = group3) gives 192 solutions, a 17KB golden and a ~0.2s
-- run, measured directly -- fast enough to no longer need the SLOW tag
-- at all (dropped from manifest.txt). Still exercises the same
-- constraint-search shape (`&>`-guarded `?` choice over test slots),
-- just at a size that doesn't turn a `git clone` into a 12MB download.
type Time = Int
type Name = String
type Student = (Name, [Time])
type Test = [Name]

capacity :: Int
capacity = 10

schedule :: [Test] -> [Student] -> [Test]
schedule tests = foldr takeTest tests

takeTest :: Student -> [Test] -> [Test]
takeTest (name, times) tests = foldr (?) failed (map (testAt name tests) times)

--testAt :: Name -> [Test] -> Time -> [Test]
--testAt name tests time
--  | length test < capacity
--  = foldr (:) ((name:test) : ts2) ts1
-- where (ts1,test:ts2) = splitAt time tests
testAt :: Name -> [Test] -> Time -> [Test]
testAt name tests time  = case splitAt time tests of
                               (ts1,test:ts2) -> length test < capacity &>
                                                  foldr (:) ((name:test) : ts2) ts1

main :: [[Name]]
main = case schedule [[],[],[]] theClass of
            []   -> id []
            x:xs -> id (x:xs)

theClass :: [Student]
theClass = foldr (:) group2 group1
--theClass = foldr (:) (foldr (:) (foldr (:) (foldr (:) group5 group4) group3) group2) group1
--theClass = group3

group1, group2, group3, group4, group5 :: [Student]
group1   = [("a1", [0]),
            ("a2", [0,2]),
            ("a3", [0,1]),
            ("a4", [1]),
            ("a5", [0,2]),
            ("a6", [1,2])]
group2   = [("a7", [0,1,2]),
            ("a8", [2]),
            ("a9", [1,2]),
            ("a10", [0]),
            ("a11", [0]),
            ("a12", [0,2])]
--group3 :: [Student]
group3   = [("a13", [0,1]),
            ("a14", [1]),
            ("a15", [0,2])]
group4   = [("a16", [2]),
            ("a17", [2,4]),
            ("a18", [2,3]),
            ("a19", [3]),
            ("a20", [2,4]),
            ("a21", [3,4])]
group5   = [("a22", [2,3,4]),
            ("a23", [4]),
            ("a24", [3,4])]
            --("a25", [2]),
            --("a26", [2]),
            --("a27", [2,4])]
