Rice against KiCS2, 2026-11-04
==============================

`tests/compare-kics2.sh` (all four program sets, default settings for
both, best of 3 alternating rounds, 120 s timeout, 6 GB memory cap).
Machine: Apple M-series Mac (arm64), 16 GB, macOS. Rice at commit
`d8ef1bf` plus the comparison script (optimizer off, its default since
2026-11-03; runtime flags at their defaults: #1, #2, #3 on, #4, #5, path
compression off). KiCS2 3.5.0, default settings, executables built with
`:save`. Both compilers' answers match the goldens for every program
both finished (compared as multisets of answers, ignoring term syntax).

Summary:
- 51 programs finished under both. Geometric mean of KiCS2's time over
  rice's: 1.44 (rice faster overall).
- Rice faster on 24, by a geometric mean of 6.1x; up to 473x
  (ExpSimpFunPats), 258x (EscherPerm), 22x (cent), 20x (PaliFunPats).
  These are the nondeterministic programs.
- KiCS2 faster on 27, by a geometric mean of 2.5x; up to 6.7x (Primes,
  PrimesBuiltin), 5.5x (Queens). These are the deterministic programs,
  where rice's time goes to type-class dictionary dispatch (current.md,
  "Rice vs KiCS2").
- KiCS2 timed out (120 s) on 5 that rice finishes in under 5 s:
  SatSolver, SearchKanMis, SearchMAC, SearchSMM, mergesort_or.
- Memory: rice uses less on most nondeterministic programs (ndtest 27 MB
  against 3.1 GB, EscherPerm 27 MB against 2.2 GB, cent 27 MB against
  1.3 GB); KiCS2 uses less on most deterministic ones (about 15 MB
  against rice's 27 to 96 MB).

"KiCS2 / rice" above 1 means rice is faster.

| program | rice (s) | KiCS2 (s) | KiCS2 / rice | rice MB | KiCS2 MB |
|---|---:|---:|---:|---:|---:|
| old_rice/benchmarks/buildFold.curry | 0.623 | 0.574 | 0.92 | 181 | 656 |
| old_rice/benchmarks/cent.curry | 0.420 | 9.424 | 22.44 | 27 | 1310 |
| old_rice/benchmarks/fib_det.curry | 0.179 | 0.189 | 1.06 | 26 | 114 |
| old_rice/benchmarks/fib.curry | 0.903 | 7.925 | 8.78 | 50 | 198 |
| scaled/old_rice/fibPeano.curry | 0.300 | 0.222 | 0.74 | 230 | 155 |
| old_rice/benchmarks/half.curry | 0.623 | 10.494 | 16.84 | 36 | 23 |
| scaled/old_rice/ndtest.curry | 0.347 | 5.433 | 15.66 | 27 | 3101 |
| scaled/old_rice/perm.curry | 0.491 | 1.843 | 3.75 | 27 | 272 |
| old_rice/benchmarks/primes.curry | 2.496 | 0.383 | 0.15 | 96 | 15 |
| old_rice/benchmarks/primesort.curry | 0.672 | 0.136 | 0.20 | 96 | 16 |
| old_rice/benchmarks/queens_det.curry | 3.054 | 0.539 | 0.18 | 37 | 14 |
| scaled/old_rice/queens_perm.curry | 0.109 | 0.152 | 1.39 | 27 | 26 |
| old_rice/benchmarks/reverse_builtin.curry | 0.888 | 0.418 | 0.47 | 1025 | 528 |
| old_rice/benchmarks/reverse_foldr.curry | 0.146 | 0.097 | 0.66 | 91 | 56 |
| old_rice/benchmarks/reverse_prim.curry | 0.135 | 0.114 | 0.84 | 95 | 66 |
| scaled/old_rice/schedule.curry | 1.345 | 0.730 | 0.54 | 27 | 190 |
| old_rice/benchmarks/sieve.curry | 0.184 | 0.070 | 0.38 | 27 | 14 |
| old_rice/benchmarks/sort.curry | 0.795 | 3.543 | 4.46 | 27 | 583 |
| old_rice/benchmarks/sum_square.curry | 0.141 | 0.080 | 0.57 | 46 | 36 |
| old_rice/benchmarks/tak.curry | 10.106 | 4.221 | 0.42 | 29 | 13 |
| scaled/kics2/ExpSimpFunPats.curry | 0.048 | 22.683 | 472.56 | 32 | 59 |
| kics2_bench/ExpVarFunPats.curry | 0.381 | 1.351 | 3.55 | 289 | 140 |
| scaled/kics2/Half.curry | 0.628 | 10.559 | 16.81 | 36 | 23 |
| kics2_bench/LastFunPats.curry | 0.155 | 0.475 | 3.06 | 145 | 188 |
| scaled/kics2/PaliFunPats.curry | 0.342 | 6.819 | 19.94 | 30 | 47 |
| kics2_bench/PermSort.curry | 0.397 | 4.040 | 10.18 | 27 | 215 |
| kics2_bench/PermSortPeano.curry | 0.540 | 4.257 | 7.88 | 27 | 230 |
| kics2_bench/Primes.curry | 0.673 | 0.137 | 0.20 | 95 | 15 |
| kics2_bench/PrimesBuiltin.curry | 2.587 | 0.393 | 0.15 | 96 | 15 |
| kics2_bench/PrimesPeano.curry | 0.399 | 0.197 | 0.49 | 35 | 15 |
| kics2_bench/Queens.curry | 3.071 | 0.556 | 0.18 | 37 | 14 |
| kics2_bench/QueensUser.curry | 3.321 | 0.675 | 0.20 | 38 | 14 |
| kics2_bench/Reverse.curry | 0.123 | 0.114 | 0.93 | 27 | 15 |
| kics2_bench/ReverseBuiltin.curry | 0.243 | 0.145 | 0.60 | 319 | 151 |
| kics2_bench/ReverseHO.curry | 0.254 | 0.107 | 0.42 | 319 | 91 |
| kics2_bench/ReverseUser.curry | 0.128 | 0.109 | 0.85 | 27 | 15 |
| kics2_bench/SatSolver.curry | 0.610 | timeout | - | 62 | - |
| kics2_bench/SearchKanMis.curry | 0.850 | timeout | - | 57 | - |
| scaled/kics2/SearchMAC.curry | 0.355 | timeout | - | 73 | - |
| kics2_bench/SearchSMM.curry | 4.861 | timeout | - | 28 | - |
| kics2_bench/ShareNonDet.curry | 0.666 | 0.139 | 0.21 | 96 | 16 |
| kics2_bench/Tak.curry | 0.435 | 0.214 | 0.49 | 27 | 12 |
| kics2_bench/TakPeano.curry | 1.166 | 0.332 | 0.28 | 27 | 12 |
| pakcs_examples/colormap_nd.curry | 0.028 | 0.040 | 1.43 | 2 | 12 |
| scaled/pakcs/EscherPerm.curry | 0.434 | 112.181 | 258.48 | 27 | 2225 |
| pakcs_examples/family_nd.curry | 0.026 | 0.040 | 1.54 | 2 | 12 |
| pakcs_examples/family_rel.curry | 0.031 | 0.048 | 1.55 | 2 | 12 |
| scaled/pakcs/mergesort_or.curry | 0.511 | timeout | - | 89 | - |
| scaled/pakcs/nondetfunc.curry | 0.493 | 3.898 | 7.91 | 27 | 586 |
| optbench/barrier.curry | 1.252 | 0.455 | 0.36 | 334 | 292 |
| optbench/copy_chain.curry | 0.180 | 0.189 | 1.05 | 27 | 114 |
| optbench/forward_chain_nd.curry | 0.206 | 0.158 | 0.77 | 80 | 37 |
| optbench/forward_chain.curry | 0.176 | 0.188 | 1.07 | 27 | 114 |
| optbench/local_search.curry | 0.313 | 1.446 | 4.62 | 343 | 42 |
| optbench/old_thunks.curry | 0.127 | 0.161 | 1.27 | 87 | 151 |
| optbench/young_nodes.curry | 1.688 | 0.592 | 0.35 | 573 | 366 |
