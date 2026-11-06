Rice against KiCS2, 2026-11-05
==============================

`tests/compare-kics2.sh` (all four program sets, default settings for
both, best of 3 alternating rounds, 120 s timeout, 6 GB memory cap).
Machine: Apple M-series Mac (arm64), 16 GB, macOS. Rice at commit
`e9a021d`: optimizer off (its default since 2026-11-03); runtime flags at
their defaults, #1, #2, #3 and #5 on, #4 and path compression off
(docs/results/optbench-2026-11-05.md). KiCS2 3.5.0, default settings,
executables built with `:save`. Both compilers' answers match the goldens
for every program both finished (compared as multisets of answers,
ignoring term syntax).

This replaces the 2026-11-04 run, which had #5 off (geometric mean 1.44,
fib 8.8x).

Summary:
- 51 programs finished under both. Geometric mean of KiCS2's time over
  rice's: 1.53 (rice faster overall).
- Rice faster on 24, by a geometric mean of 6.7x; up to 477x
  (ExpSimpFunPats), 271x (EscherPerm), 45x (fib), 22x (cent), 20x
  (PaliFunPats). These are the nondeterministic programs.
- KiCS2 faster on 27, by a geometric mean of 2.4x; up to 6.7x (Primes,
  PrimesBuiltin), 5.5x (Queens). These are the deterministic programs,
  where rice's time goes to type-class dictionary dispatch.
- KiCS2 timed out (120 s) on 5 that rice finishes in under 5 s:
  SatSolver, SearchKanMis, SearchMAC, SearchSMM, mergesort_or.
- Memory: rice uses less on most nondeterministic programs (ndtest 27 MB
  against 3.1 GB, EscherPerm 27 MB against 2.2 GB, cent 27 MB against
  1.3 GB); KiCS2 uses less on most deterministic ones (about 15 MB
  against rice's 27 to 96 MB).

"KiCS2 / rice" above 1 means rice is faster.

| program | rice (s) | KiCS2 (s) | KiCS2 / rice | rice MB | KiCS2 MB |
|---|---:|---:|---:|---:|---:|
| old_rice/benchmarks/buildFold.curry | 0.662 | 0.604 | 0.91 | 181 | 656 |
| old_rice/benchmarks/cent.curry | 0.428 | 9.543 | 22.30 | 27 | 1310 |
| old_rice/benchmarks/fib_det.curry | 0.180 | 0.184 | 1.02 | 26 | 114 |
| old_rice/benchmarks/fib.curry | 0.181 | 8.073 | 44.60 | 26 | 198 |
| scaled/old_rice/fibPeano.curry | 0.335 | 0.230 | 0.69 | 231 | 155 |
| old_rice/benchmarks/half.curry | 0.605 | 10.561 | 17.46 | 29 | 23 |
| scaled/old_rice/ndtest.curry | 0.345 | 5.492 | 15.92 | 27 | 3101 |
| scaled/old_rice/perm.curry | 0.514 | 1.848 | 3.60 | 27 | 272 |
| old_rice/benchmarks/primes.curry | 2.672 | 0.391 | 0.15 | 96 | 15 |
| old_rice/benchmarks/primesort.curry | 0.716 | 0.137 | 0.19 | 96 | 16 |
| old_rice/benchmarks/queens_det.curry | 3.154 | 0.570 | 0.18 | 37 | 14 |
| scaled/old_rice/queens_perm.curry | 0.096 | 0.144 | 1.50 | 27 | 26 |
| old_rice/benchmarks/reverse_builtin.curry | 0.924 | 0.424 | 0.46 | 1025 | 528 |
| old_rice/benchmarks/reverse_foldr.curry | 0.147 | 0.100 | 0.68 | 91 | 56 |
| old_rice/benchmarks/reverse_prim.curry | 0.138 | 0.109 | 0.79 | 95 | 66 |
| scaled/old_rice/schedule.curry | 1.405 | 0.733 | 0.52 | 27 | 190 |
| old_rice/benchmarks/sieve.curry | 0.179 | 0.063 | 0.35 | 27 | 14 |
| old_rice/benchmarks/sort.curry | 0.820 | 3.560 | 4.34 | 27 | 583 |
| old_rice/benchmarks/sum_square.curry | 0.130 | 0.084 | 0.65 | 46 | 36 |
| old_rice/benchmarks/tak.curry | 10.374 | 4.549 | 0.44 | 29 | 13 |
| scaled/kics2/ExpSimpFunPats.curry | 0.048 | 22.893 | 476.94 | 28 | 59 |
| kics2_bench/ExpVarFunPats.curry | 0.265 | 1.364 | 5.15 | 149 | 140 |
| scaled/kics2/Half.curry | 0.601 | 10.568 | 17.58 | 29 | 23 |
| kics2_bench/LastFunPats.curry | 0.146 | 0.471 | 3.23 | 141 | 188 |
| scaled/kics2/PaliFunPats.curry | 0.352 | 6.966 | 19.79 | 29 | 47 |
| kics2_bench/PermSort.curry | 0.415 | 4.121 | 9.93 | 27 | 215 |
| kics2_bench/PermSortPeano.curry | 0.568 | 4.323 | 7.61 | 27 | 230 |
| kics2_bench/Primes.curry | 0.697 | 0.138 | 0.20 | 95 | 15 |
| kics2_bench/PrimesBuiltin.curry | 2.623 | 0.386 | 0.15 | 96 | 15 |
| kics2_bench/PrimesPeano.curry | 0.407 | 0.200 | 0.49 | 35 | 15 |
| kics2_bench/Queens.curry | 3.127 | 0.549 | 0.18 | 37 | 14 |
| kics2_bench/QueensUser.curry | 3.537 | 0.675 | 0.19 | 38 | 14 |
| kics2_bench/Reverse.curry | 0.133 | 0.125 | 0.94 | 27 | 15 |
| kics2_bench/ReverseBuiltin.curry | 0.252 | 0.149 | 0.59 | 319 | 151 |
| kics2_bench/ReverseHO.curry | 0.248 | 0.115 | 0.46 | 319 | 91 |
| kics2_bench/ReverseUser.curry | 0.132 | 0.112 | 0.85 | 27 | 15 |
| kics2_bench/SatSolver.curry | 0.212 | timeout | - | 34 | - |
| kics2_bench/SearchKanMis.curry | 0.372 | timeout | - | 70 | - |
| scaled/kics2/SearchMAC.curry | 0.363 | timeout | - | 74 | - |
| kics2_bench/SearchSMM.curry | 4.559 | timeout | - | 28 | - |
| kics2_bench/ShareNonDet.curry | 0.700 | 0.148 | 0.21 | 96 | 16 |
| kics2_bench/Tak.curry | 0.430 | 0.211 | 0.49 | 27 | 12 |
| kics2_bench/TakPeano.curry | 1.188 | 0.332 | 0.28 | 27 | 12 |
| pakcs_examples/colormap_nd.curry | 0.029 | 0.042 | 1.45 | 2 | 12 |
| scaled/pakcs/EscherPerm.curry | 0.415 | 112.350 | 270.72 | 27 | 2225 |
| pakcs_examples/family_nd.curry | 0.031 | 0.044 | 1.42 | 2 | 12 |
| pakcs_examples/family_rel.curry | 0.035 | 0.048 | 1.37 | 2 | 12 |
| scaled/pakcs/mergesort_or.curry | 0.511 | timeout | - | 89 | - |
| scaled/pakcs/nondetfunc.curry | 0.493 | 3.895 | 7.90 | 27 | 586 |
| optbench/barrier.curry | 0.741 | 0.455 | 0.61 | 331 | 292 |
| optbench/copy_chain.curry | 0.176 | 0.182 | 1.03 | 27 | 114 |
| optbench/forward_chain_nd.curry | 0.210 | 0.162 | 0.77 | 80 | 37 |
| optbench/forward_chain.curry | 0.176 | 0.189 | 1.07 | 27 | 114 |
| optbench/local_search.curry | 0.322 | 1.446 | 4.49 | 336 | 42 |
| optbench/old_thunks.curry | 0.124 | 0.175 | 1.41 | 87 | 151 |
| optbench/young_nodes.curry | 0.735 | 0.598 | 0.81 | 437 | 366 |
