// Hand-written smoke test for runtime/ (Phase 0 -- see docs/history/status-2026-09.md's
// "runtime/ and Codegen" section, and docs/history/codegen-runtime-review.md's case
// for testing the runtime directly, decoupled from codegen). Builds a few
// small node graphs by hand, straight against runtime.h's own
// set0/set1/set2/make_choice/etc., the same way codegen will eventually --
// no generated .c/.h involved, no external.c/Prelude_external.* (both still
// need Phase 1's generated Prelude.h to even compile). Confirms Phase 0's
// fixes actually work, not just compile.
//
// Build/run: `make test` from runtime/ (see runtime/Makefile).
//
// Three checks:
//   1. Symbol.payload -- the core design change from this session: a
//      hand-built "boxed Int"-shaped node (one child holding a raw long,
//      .payload = PAYLOAD_INT on its Symbol) prints as a bare number, not
//      as an applied constructor -- confirms print_final/print_expr read
//      the payload correctly, with no runtime-hardcoded int_symbol/INT_CTR
//      involved at all.
//   2. choose/undo/nf_all -- Choice(True, False) should yield exactly two
//      solutions, "True" and "False", exercising push_node, the
//      backtracking stack, and fail_nf's TEST-level-independent definition
//      together.
//   3. fail_nf -- Pair(FAIL, True), reduced with nf(), should collapse the
//      whole Pair to FAIL (not just leave the FAIL buried in a child) --
//      confirms fail_nf's `root`-not-`node` fix.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "node.h"
#include "runtime.h"


static int failures = 0;

static void check(int cond, const char* what)
{
    if(cond)
    {
        printf("PASS: %s\n", what);
    }
    else
    {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static int count_occurrences(const char* haystack, const char* needle)
{
    int n = 0;
    const char* p = haystack;
    while((p = strstr(p, needle)) != NULL)
    {
        n++;
        p += strlen(needle);
    }
    return n;
}

static union field mk0(Symbol* sym)
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
    set0(n, sym);
    return n;
}

static union field mk2(Symbol* sym, union field v0, union field v1)
{
    union field n;
    n.n = (Node*)alloc(sizeof(Node));
    set2(n, sym, v0, v1);
    return n;
}

// Ordinary 0-arity constructors -- tags only need to be distinct from the
// five reserved ones (FAIL/FUNCTION/CHOICE/FORWARD/FREE, 0..4) and from
// each other *within whatever switch would scrutinize them together*;
// reusing tag 5 across true/pair/boxed_int here is deliberate, the same way
// codegen will reuse it across unrelated types -- nothing in this test ever
// needs a bare tag to disambiguate a type on its own, only symbol identity
// (print_final's name lookup) or, for the boxed value, its Symbol's
// .reps (box_rep) -- exactly the design this checks.
static Symbol true_symbol      = { .tag = 5, .arity = 0, .name = "True",  .hnf = &CTR_hnf };
static Symbol false_symbol     = { .tag = 6, .arity = 0, .name = "False", .hnf = &CTR_hnf };
static Symbol pair_symbol      = { .tag = 5, .arity = 2, .name = "Pair",  .hnf = &CTR_hnf };
static const unsigned char boxed_int_reps[] = { R_INT };
static Symbol boxed_int_symbol = { .tag = 5, .arity = 1, .name = "Int",
                                    .reps = boxed_int_reps, .hnf = &CTR_hnf };

int main(void)
{
    runtime_init();

    // Capture everything printed to stdout by the runtime calls below, so
    // the checks can be automated (grep the captured text) instead of
    // needing a human to eyeball the output.
    fflush(stdout);
    char path[] = "/tmp/rice_runtime_smoke_XXXXXX";
    int fd = mkstemp(path);
    if(fd < 0)
    {
        perror("mkstemp");
        return 1;
    }
    int saved_stdout = dup(STDOUT_FILENO);
    dup2(fd, STDOUT_FILENO);

    // --- Check 1: Symbol.payload -----------------------------------
    union field iv;
    iv.i = 42;
    union field boxedInt = { .n = (Node*)alloc(sizeof(Node)) };
    set1(boxedInt, &boxed_int_symbol, iv);
    print_final(boxedInt);
    printf("\n");

    // --- Check 2: choose/undo/nf_all --------------------------------
    union field t = mk0(&true_symbol);
    union field f = mk0(&false_symbol);
    union field choiceNode = make_choice(t, f);
    nf_all(choiceNode);

    // --- Check 3: fail_nf --------------------------------------------
    union field failNode = { .n = (Node*)alloc(sizeof(Node)) };
    fail(failNode);
    union field pairNode = mk2(&pair_symbol, failNode, mk0(&true_symbol));
    nf(pairNode);
    printf("pair-after-nf-tag: %d (expect %d)\n", TAG(pairNode), FAIL_TAG);

    fflush(stdout);
    dup2(saved_stdout, STDOUT_FILENO);
    close(saved_stdout);
    close(fd);

    FILE* captured = fopen(path, "r");
    char buf[8192] = {0};
    size_t n = 0;
    if(captured != NULL)
    {
        n = fread(buf, 1, sizeof(buf) - 1, captured);
        fclose(captured);
    }
    buf[n] = '\0';
    unlink(path);

    printf("--- captured runtime output ---\n%s--- end captured output ---\n\n", buf);

    check(strstr(buf, "42") != NULL,
          "Symbol.payload: boxed Int prints as a raw value (no int_symbol/INT_CTR involved)");
    check(count_occurrences(buf, "SOLUTION:") == 2 &&
          strstr(buf, "True") != NULL && strstr(buf, "False") != NULL,
          "choose/undo/nf_all: Choice(True, False) finds both solutions");
    check(strstr(buf, "pair-after-nf-tag: 0 (expect 0)") != NULL,
          "fail_nf: a FAIL child collapses its Pair parent to FAIL");

    // The evaluation stack: enough frames to force several machine_grow
    // calls, each slot tagged with its frame's index, all checked after
    // the moves, then popped back to empty.
    {
        static const unsigned char test_reps[] = { R_INT, R_PTR };
        static const FrameInfo test_info =
            { .code = NULL, .size = 2, .reps = test_reps, .name = "test" };
        Frame* sp = rice_sp;
        ptrdiff_t base = machine_depth(sp);
        const long N = 100000;
        for(long i = 0; i < N; i++)
        {
            sp = frame_push(sp, &test_info);
            sp->slots[0].i = i;
        }
        int intact = machine_depth(sp) - base == N * 3;
        Frame* f = sp;
        for(long i = N - 1; i >= 0 && intact; i--)
        {
            intact = f->info == &test_info && f->slots[0].i == i && f->slots[1].n == NULL;
            f = (Frame*)((union field*)f + 3);
        }
        check(intact, "machine: 100000 frames survive stack growth intact");
        for(long i = 0; i < N; i++)
        {
            sp = frame_pop(sp);
        }
        check(machine_depth(sp) == base, "machine: popping every frame returns to the start");
    }

    printf("\n%s\n", failures == 0 ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED");
    return failures == 0 ? 0 : 1;
}
