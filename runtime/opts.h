#ifndef OPTS_H
#define OPTS_H

// The runtime's compile-time flags. node.h includes this first, because
// the node layout itself depends on OPT_EPOCH_TRAIL: a default set anywhere
// later would come too late for it.

/* The backtracking optimizations (developer's manual, "Making backtracking
 * cheaper"; the rules are in the developer's manual, "Soundness rules").
 * Each one is its own 0/1 flag so we can turn them on and off independently
 * (-DOPT_EPOCH_TRAIL=1 on the command line, or rice's RICE_CFLAGS).
 *  * OPT_NONDET_TRAIL (#1): only trail a rewrite if it read something nondeterministic.
 *  * OPT_SCOPED_BACKTRACK (#3): when a case fails, retry choices made since the case began first.
 *  * OPT_COPY_COLLAPSE (#4): collapse to a copy of a finished value instead of a FORWARD.
 *  * OPT_EPOCH_TRAIL (#5): don't trail nodes created after the last choice point.
 *  * OPT_PATH_COMPRESS: when a case reads a forward, retarget it past the
 *    deterministic forwards behind it (follow_forward below).
 *  * OPT_WRITE_BARRIER: stamp nodes built by a deterministic rewrite as old
 *    as the node they're built for (rewrite_stamp below).
 *    It's required when #1 and #5 are both on, and on by default then.
 * Every subset of these is proved to give the baseline's answers on a model
 * of the machine (developer's manual, "Soundness rules"), given the barrier when #1 and #5 are both on.
 * #4 and path compression are off by default: measured on 56 programs
 * (docs/results/optbench-2026-11-05.md), neither changed run time by more
 * than noise, either way. #5 is on: it saves 9% on average with #1 on, up
 * to 5x, and costs at most 9%.
 *  * OPT_TAIL_DISPATCH (#2): a tail call jumps straight to the callee's code.
 *    Off, it goes through redispatch (runtime.c) instead, the way a
 *    trampoline would: check root's tag, then jump through root's symbol.
 *    Both are musttail jumps, so the C stack is the same either way;
 *    off only exists to measure what #2 saves.
 */
#ifndef OPT_NONDET_TRAIL
#define OPT_NONDET_TRAIL 1
#endif
#ifndef OPT_TAIL_DISPATCH
#define OPT_TAIL_DISPATCH 1
#endif
#ifndef OPT_SCOPED_BACKTRACK
#define OPT_SCOPED_BACKTRACK 1
#endif
#ifndef OPT_COPY_COLLAPSE
#define OPT_COPY_COLLAPSE 0
#endif
#ifndef OPT_EPOCH_TRAIL
#define OPT_EPOCH_TRAIL 1
#endif
#ifndef OPT_PATH_COMPRESS
#define OPT_PATH_COMPRESS 0
#endif
#ifndef OPT_WRITE_BARRIER
#define OPT_WRITE_BARRIER (OPT_NONDET_TRAIL && OPT_EPOCH_TRAIL)
#endif

/* #1 and #5 are each sound alone, but not together without the barrier.
 * #1 leaves an old node's deterministic rewrite untrailed,
 * so it can end up pointing at a young node whose rewrite #5 didn't trail
 * (tests/programs/regressions/stale_apply.curry).
 * The barrier makes that young node look as old as the node it hangs from.
 * #5 without #1 is proved with the barrier off, so it's only on by default with both.
 */
// -DOPT_ALLOW_UNSOUND=1 builds the combination anyway,
// only to check that the regression tests catch it (stale_mk.curry and friends).
#if OPT_NONDET_TRAIL && OPT_EPOCH_TRAIL && !OPT_WRITE_BARRIER && !OPT_ALLOW_UNSOUND
#error "OPT_NONDET_TRAIL with OPT_EPOCH_TRAIL needs OPT_WRITE_BARRIER"
#endif
#if OPT_WRITE_BARRIER && !OPT_EPOCH_TRAIL
#error "OPT_WRITE_BARRIER only means something with OPT_EPOCH_TRAIL"
#endif

#endif // OPTS_H
