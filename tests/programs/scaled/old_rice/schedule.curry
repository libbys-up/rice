-- Scaled-up copy of tests/programs/old_rice/benchmarks/schedule.curry, for optbench.sh's timing:
-- All five groups and five test slots, the original program's own
-- class (72,288 schedules). Only the 210 whose tests have 6, 6, 6, 4
-- and 2 students are printed (`balanced`).

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

testAt :: Name -> [Test] -> Time -> [Test]
testAt name tests time  = case splitAt time tests of
                               (ts1,test:ts2) -> length test < capacity &>
                                                  foldr (:) ((name:test) : ts2) ts1

main :: [[Name]]
main = case schedule [[],[],[],[],[]] theClass of
            []   -> id []
            x:xs -> balanced (x:xs) &> (x:xs)

theClass :: [Student]
theClass = foldr (:) (foldr (:) (foldr (:) (foldr (:) group5 group4) group3) group2) group1

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

-- Only the schedules whose tests have 6, 6, 6, 4 and 2 students.
balanced :: [Test] -> Bool
balanced ts = map length ts == [6, 6, 6, 4, 2]
