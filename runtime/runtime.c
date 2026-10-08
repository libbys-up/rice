#include<stdbool.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>
#include<stdint.h>
#include<errno.h>
#include<sys/resource.h>
#include "runtime.h"

#include "node.h"
#include "stack.h"
#include "debug.h"

// Note:
// (void)var;
// is used to suppress variable not used warnings, so we can use -Wall.

// backtracking-optimizations.md's #5 -- see its own doc comment on the
// `extern` declaration, runtime.h. Defined here (not in generated main.c,
// unlike bt_stack/mem) since nothing about it is per-program: every build
// links this file exactly once.
unsigned int current_epoch = 0;

// The --stack-size flag (Rice.Main/Rice.Codegen.C.ToC's writeMain): a
// stopgap for genuine non-tail recursion (foldr over a long list, etc.)
// that OPT_TAIL_JUMP's trampoline can't help with, since it isn't a tail
// call to begin with -- the C call stack genuinely grows one frame per
// element. Only ever raises the *current process's own* limit (never
// lowers it, and a request no bigger than what's already in effect is a
// silent no-op) -- this is not the same as a user running `ulimit -s`
// themselves beforehand, which nothing here requires. Bounded by
// whatever the OS's own hard limit (RLIM_MAX) currently allows: on
// Linux that's commonly unlimited or very large; on macOS it defaults to
// 64MB regardless of how much RAM is actually available, confirmed by
// testing on this platform -- `set_stack_size_max` reads the real hard
// limit at run time rather than hardcoding either number, since it
// isn't known at compile time and varies by machine either way.
// A failure here is a warning, not fatal: running with less stack than
// asked for is still better than refusing to run the program at all.
static void raise_stack_limit(rlim_t want)
{
    struct rlimit rl;
    if (getrlimit(RLIMIT_STACK, &rl) != 0)
    {
        fprintf(stderr, "warning: --stack-size: getrlimit failed (%s)\n", strerror(errno));
        return;
    }
    if (rl.rlim_max != RLIM_INFINITY && want > rl.rlim_max)
    {
        // Asking setrlimit for more than the hard limit doesn't clamp
        // to it -- confirmed by testing: it fails outright (EINVAL) and
        // leaves the limit completely unchanged. Clamping here first is
        // what makes "give me as much as you'll allow" actually work.
        want = rl.rlim_max;
    }
    if (want <= rl.rlim_cur)
    {
        return;
    }
    rl.rlim_cur = want;
    if (setrlimit(RLIMIT_STACK, &rl) != 0)
    {
        fprintf(stderr,
                "warning: --stack-size: couldn't raise the stack limit "
                "(wanted %llu bytes: %s) -- continuing with the current limit\n",
                (unsigned long long)want, strerror(errno));
    }
}

void set_stack_size(unsigned long bytes)
{
    raise_stack_limit((rlim_t)bytes);
}

void set_stack_size_max(void)
{
    struct rlimit rl;
    if (getrlimit(RLIMIT_STACK, &rl) != 0)
    {
        fprintf(stderr, "warning: --stack-size=max: getrlimit failed (%s)\n", strerror(errno));
        return;
    }
    raise_stack_limit(rl.rlim_max);
}


static void CTR_impl(void)
{
    field root = rice_root;
    (void)root; // unused when DEBUG == 0, since debug_expr expands to nothing
    debug(LOW, "HNF constructor:");
    debug_expr(LOW, root);
}

static void choice_impl(void)
{
    field root = rice_root;
    debug(LOW, "HNF choice:");
    debug_expr(LOW, root);
    choose(root);
}

// Sets free variable n to the constructor of `like`, with a fresh free
// variable for every pointer child -- a core piece of a narrowing step.
// A raw child can't be a free variable (a raw slot holds no node to bind
// later), and has no structure left to narrow, so it takes `like`'s own
// value instead.
void set_free_constructor(union field n, union field like)
{
    Symbol* sym = like.n->symbol;
    n.n->symbol = sym;
    n.n->missing = 0;
    n.n->nondet = true;
    n.n->children[0].n = NULL;
    n.n->children[1].n = NULL;
    n.n->children[2].n = NULL;
    n.n->children[3].a = NULL;
    if(sym->arity > 3)
    {
        n.n->children[3].a = (union field*)alloc((sym->arity - 3) * sizeof(union field));
    }
    for(unsigned int i = 0; i < sym->arity; i++)
    {
        set_child_at(n, i, child_rep(sym, i) == R_PTR ? free_var()
                                                       : child_at_v(like, i));
    }
}

// Narrowing a free variable to a constructor with a raw field would put a
// free variable in a raw slot. Raw values can't be narrowed this way
// (literal-case narrowing isn't implemented), so stop with a clear
// message instead of corrupting the node.
void narrow_raw_error(Symbol* sym)
{
    fprintf(stderr, "Error: can't narrow a free variable to %s: "
                    "it has a raw (unboxed) field\n", sym->name);
    exit(1);
}

// copy node into new_node
union field set_copy(union field new_node, union field node)
{
#if OPT_EPOCH_TRAIL
    // `new_node`'s memory keeps its own age -- overwriting its *content*
    // from `node` here isn't a new allocation, the same reasoning as
    // set_X's own hnf functions never touching epoch (Rice.Codegen.C.ToH).
    // This matters concretely: apply_hnf calls this to overwrite `root`
    // (typically long-lived) with a callee's shape; memcpy-ing `node`'s
    // epoch straight over root's own would let an old node suddenly read
    // as young (or vice versa) for reasons having nothing to do with when
    // root's memory was actually allocated.
    unsigned int keep_epoch = new_node.n->epoch;
#endif
    memcpy(new_node.n, node.n, sizeof(Node));
#if OPT_EPOCH_TRAIL
    new_node.n->epoch = keep_epoch;
#endif
    int arity = node.n->symbol->arity;
    int size = (arity-3)*sizeof(union field);
    if(arity > 3)
    {
        new_node.n->children[3].a = (union field*)alloc(size);
        memcpy(new_node.n->children[3].a, node.n->children[3].a, size);
    }
    return new_node;
}

// CLAUDE: What does this function do that different than set_copy?
// Do we need both?
union field set_copy_free(union field new_node, union field node)
{
    int arity = node.n->symbol->arity;
    for(int i = 0; i < arity; i++)
    {
        if(child_rep(node.n->symbol, i) != R_PTR)
        {
            narrow_raw_error(node.n->symbol);
        }
    }

    new_node.n = (Node*)alloc(sizeof(Node));
#if OPT_EPOCH_TRAIL
    new_node.n->epoch = current_epoch;
#endif
    new_node.n->missing = node.n->missing;
    new_node.n->nondet = true;
    int size = (arity-3)*sizeof(union field);
    if(arity > 3)
    {
        new_node.n->children[3].a = (union field*)alloc(size);
    }
    for(int i = 0; i < arity; i++)
    {
        set_child_at(new_node, i, free_var());
    }
    return new_node;
}

// create a copy of node.
union field copy(union field node)
{
    union field new;
    new.n = (Node*)alloc(sizeof(Node));
#if OPT_EPOCH_TRAIL
    // Stamped *before* set_copy, which preserves whatever epoch is
    // already sitting in the destination rather than copying `node`'s --
    // this is a fresh allocation, so its own epoch is "now", same as any
    // other freshly alloc'd node, not the source's age.
    new.n->epoch = current_epoch;
#endif
    set_copy(new, node);
    return new;
}

// apply_hnf fills slots [from, from+count) of a partial application with
// argument pointers. The compiler never partially applies a function with
// a raw parameter (Rice.Codegen.FieldReps' lint), so in a debug build
// check that every slot being filled really is a pointer slot.
static inline void check_fill_ptrs(Symbol* sym, int from, int count)
{
#if DEBUG > 0
    for(int i = from; i < from + count; i++)
    {
        if(child_rep(sym, i) != R_PTR)
        {
            fprintf(stderr, "Error: apply would put a pointer in raw slot %d of %s\n",
                    i, sym->name);
            exit(1);
        }
    }
#else
    (void)sym; (void)from; (void)count;
#endif
}

// reduce a node rooted by apply(PART(f,y1,y2...yn), x1, x2 ... xn)
// apply(PART(f,y1,...), x1, ...) on the evaluation machine. apply_hnf
// pushes a frame [root, f, nondet] and enters apply_k, the loop that
// evaluates f to a partial application: evaluating f jumps to f's code,
// which returns into apply_k. Once f is a PART, the frame is popped and
// the arguments filled in; a now fully applied call is then a tail jump.
static const unsigned char apply_reps[] = { R_PTR, R_PTR, R_INT };
static RICE_CC void apply_k(void);
static const FrameInfo apply_info =
    { .code = apply_k, .size = 3, .reps = apply_reps, .name = "apply" };

RICE_CC void apply_hnf(void)
{
    field root = rice_root;
    debug(LOW, "HNF apply: \n");
    debug_expr(LOW, root);
    frame_push(&apply_info);
    SLOT(0) = root;
    SLOT(1) = child_at(root, 0);
    SLOT(2).i = false;
    MUSTTAIL return apply_k();
}

static RICE_CC void apply_k(void)
{
    field root = SLOT(0);
    union field f = SLOT(1);
    bool nondet = SLOT(2).i;

    //This is the normal HNF loop
    //f should be a partial application,
    //so it must be missing arguments.
    //If it's not missing arguments, then it's not in HNF.
    //Evaluate f until it is.
    while(f.n->missing <= 0)
    {
        nondet |= f.n->nondet;
        switch(TAG(f))
        {
            case FAIL_TAG:
                debug(HIGH, "apply FAIL\n");
                frame_pop();
                push_node(root,nondet);
                fail(root);
                RETURN();

            case FUNCTION_TAG:
                debug(HIGH, "apply FUNCTION\n");
                // f must be fully applied, or we would have left the loop!
                SLOT(1) = f;
                SLOT(2).i = nondet;
                rice_root = f;
                MUSTTAIL return f.n->symbol->hnf();

            case CHOICE_TAG:
                debug(HIGH, "apply CHOICE\n");
                choose(f);
                break;

            case FORWARD_TAG:
                debug(HIGH, "apply FORWARD\n");
                nondet |= f.n->nondet;
                f = child_at(f,0);
                break;

            case FREE_TAG:
                debug(HIGH, "apply FREE\n");
                // we can't actually apply a free variable
                // because we don't know what function to make it.
                fprintf(stderr, "Cannot apply free variable!\n");
                exit(1);

            // A plain constructor in the function position: this apply
            // node should never have been built with it. Fail loudly.
            default:
                error("apply: not a function", f);
        }
    }
    frame_pop();

    union field child1 = root.n->children[1];
    union field child2 = root.n->children[2];
    union field* array = root.n->children[3].a;

    // Now we're guaranteed to have a partial application
    debug(HIGH, "apply PART\n");

    nondet |= f.n->nondet;

    push_node(root,nondet);

    // number of arguments that we're applying
    int nargs = -root.n->missing;

    // number of arguments we have left
    int missing = f.n->missing;

    debug_expr(HIGH, f);
    debug(HIGH, "arity = %d\nmissing = %d\nnargs = %d\n", 
                f.n->symbol->arity, missing, nargs);
    debug(HIGH, "missing > nargs %d\n", missing > nargs);

    // we are either underapplied, or have exactly the right amount of args.
    // Make root a copy of f, and add all of the arguments we're missing.
    // If we're fully applied, then we can evaluate root.
    if(nargs <= missing)
    {
        debug(HIGH, "under/fully applied (%d/%d)\n",
                    f.n->missing, nargs);
        debug_expr(HIGH, f);
        //hold the old array of children.
        //we'll need to move this to a bigger array
        set_copy(root,f);

        // Where the *first* still-missing argument slot lives, under
        // Rice.Codegen.C.ToH's forward child-storage (child 0 is the
        // first argument, ..., a "missing" argument occupies one of the
        // last `missing` slots, in the same left-to-right order the
        // arguments themselves arrive in) -- v1 (child1 below, despite
        // the name: see set_apply1/2/3's own reversed storage for *this*
        // apply node's own new arguments, which the local variable names
        // here are labeled after) fills this slot first, then each
        // subsequent argument fills the next slot up. This used to be
        // `missing-1`, matching old_rice's own *reversed* child storage;
        // that stopped matching once ToH switched to forward storage
        // (archetecture.md's "Boxed primitives" era predates that
        // change) -- confirmed as a real, live bug by running old_rice's
        // own benchmark suite through the finished Phase 1 compiler: any
        // partial application of 2+ missing arguments silently overwrote
        // an already-supplied argument instead of filling the real empty
        // slot, leaving the true slot NULL.
        int fillIdx = f.n->symbol->arity - missing;
        check_fill_ptrs(f.n->symbol, fillIdx, nargs);
        while(nargs > 2)
        {
            debug_expr(HIGH, array[nargs-3]);
            set_child_at(root, fillIdx, array[nargs-3]);
            fillIdx++;
            missing--;
            nargs--;
        }
        if(nargs > 1)
        {
            debug_expr(HIGH, child2);
            set_child_at(root, fillIdx, child2);
            fillIdx++;
            missing--;
        }

        // we have at least one node, or we wouldn't have an apply node.
        debug_expr(HIGH, child1);
        set_child_at(root, fillIdx, child1);
        missing--;

        root.n->missing = missing;

        debug(HIGH, "after applying\n");
        debug_expr(HIGH, root);

        //we're fully applied, and we have a choice/fail,
        //so reduce root.
        if(missing == 0 && (TAG(f) == CHOICE_TAG ||
                            TAG(f) == FUNCTION_TAG))
        {
            debug(HIGH, "before HNF call\n");
            debug_expr(HIGH, root);
            // backtracking-optimizations.md's #2: root is now a genuine
            // tail call (root itself, freshly built as f's own shape,
            // fully applied) -- under OPT_TAIL_JUMP this returns with
            // root left as-is instead of dispatching it here, same as a
            // generated function body's own tail call; apply_hnf's own
            // caller was reached via the identical TAIL_DISPATCH
            // mechanism (ToC.curry's `hnfCall "apply"`), so whatever's
            // waiting further up the chain is what redispatches this.
            rice_root = root;
            MUSTTAIL return root.n->symbol->hnf();
        }
        debug(HIGH, "leaving apply\n");
        debug_expr(HIGH, root);
        RETURN();
    }
    else
    {
        // We're overapplied, so 
        //  * add all the arguments,
        //  * reduce root
        //  * try again.
        debug(HIGH, "too many args (%d/%d)\n", f.n->missing, nargs);
        debug_expr(HIGH, f);
       
        // we need a copy of f, 
        // because this one is applied to more arguments.
        // Other parts of the program might also reference that
        // old partial application.
        union field newf = copy(f);
        debug_expr(LOW, newf);

        // copy arguments -- same forward-slot fix as the under/fully-
        // applied branch above (`fillIdx`, not `missing-1`): this loop
        // fills newf's (f's own, forward-laid-out) still-missing slots
        // from the earliest-supplied argument onward, so the target
        // index must count up from the first missing slot, not down from
        // the last one.
        int fillIdx = newf.n->symbol->arity - missing;
        check_fill_ptrs(newf.n->symbol, fillIdx, missing);
        while(missing > 0)
        {
            set_child_at(newf, fillIdx, child_at_v(root, nargs));
            fillIdx++;
            nargs--;
            missing--;
        }

        // reduce the fully applied function
        debug(HIGH, "fully applied child\n");
        debug_expr(HIGH, newf);
        newf.n->missing = 0;
        // Same reasoning as the under/fully-applied branch's TAIL_DISPATCH_PTR
        // above -- and safe to defer here even though the very next lines
        // read `newf` again (`child_at(root,0) = newf`, `apply_hnf(root)`
        // below): a deferred `newf` left as FUNCTION_TAG gets picked back
        // up correctly by apply_hnf's own re-entry, since its `f`-
        // resolution loop (the `while(f.n->missing <= 0)` loop above)
        // already re-tests TAG(f) every iteration regardless of whether
        // this call actually ran.
        // newf is a fully applied call. It isn't evaluated here: the
        // re-entered apply's own loop evaluates it as its function, the
        // same order as before, on the machine stack.
        child_at(root,0) = newf;
        root.n->missing = -nargs;
        debug(HIGH, "new apply node\n");
        debug_expr(HIGH, root);

        // We're still overapplied so try again
        rice_root = root;
        MUSTTAIL return apply_hnf();
    }
}


static void forward_impl(void) { field root = rice_root; (void)root; }

//////////////////////////////////////////////////////////////////////////////
// code for backtracking
//////////////////////////////////////////////////////////////////////////////

// push (node -> copy(node)) on the stack, leaving node itself unchanged.
// A whole-node memcpy, so the snapshot keeps node's own epoch and nondet
// flag, and undo() puts both back.
void save_snapshot(union field node)
{
    union field saved;
    saved.n = (Node*)alloc(sizeof(Node));
    memcpy(saved.n, node.n, sizeof(Node));
    stack_push(bt_stack, node, saved, false);
}

// save_snapshot, then mark node nondet. Always trails: used where the
// trail is unconditional (free-variable bindings, fail_nf). Rewrites of a
// node with its own reduct go through trail_node (runtime.h) instead.
void save_copy(union field node)
{
    save_snapshot(node);
    node.n->nondet = true;
}

// push (n -> saved) on the backtracking stack)
void save(union field n, union field saved)
{
    debug(HIGH, "save: ");
    debug_expr(HIGH, n);
    debug_expr(HIGH, saved);
    n.n->nondet = true;
    stack_push(bt_stack, n, saved, false);
}

// push (left -> right) on the backtracking stack.
// Not sure this is used.
void push_frame(union field left, union field right)
{
    stack_push(bt_stack, left, right, false);
}

// push (left ->? right) on the backtracking stack.
// This is the stopping point while backtracking.
//
// A genuine choice point (narrowing a free variable to one of several
// possible constructors, same as choose() below for a `?`) -- so under
// OPT_EPOCH_TRAIL this is one of the two places (with choose()) that
// advances current_epoch. stack_push captures the *pre*-increment value
// into this frame first (runtime.h's own doc comment on why that's always
// safe to do unconditionally); incrementing after is what makes anything
// allocated from here on read as younger than this choice point.
void push_choice(union field left, union field right)
{
    stack_push(bt_stack, left, right, true);
#if OPT_EPOCH_TRAIL
    current_epoch++;
#endif
}

// Given a node ?(left, right, side), reduce it to either left or right.
// if side == 0, then reduce to FORWARD(left)
// if side == 1, then reduce to FORWARD(right)
// The point here is that we keep all of the information, so I can fully undo this later.
// ?(left, right, false) reduces to FORWARD(left) and backtracks to ?(left,right,true)
// ?(left, right, true) reduces to FORWARD(right) and backtracks to ?(left,right,false)
// For the nondet optimization only FORWARD(left) is marked as non-deterministic.
// 
// if we reduce to left, then we will backtrack later
// so our backtracking condition is side == 0
// We flip the side value to indicate that we want to reduce to the other side next time.
void choose(union field root)
{
    debug(HIGH, "in choice\n");
    //choices = {left, right}
    //side == 0 -> left
    //side == 1 -> right
    //
    //This array should get optimized out by the C compiler.
    union field choices[2] = {child_at(root,0), child_at(root,1)};
    int side = child_at_i(root,2);

    union field saved;
    saved.n = (Node*)alloc(sizeof(Node));

    //save = left ? right
    //make a copy of root to push on the stack
    //swap if we're using left/right node
    //push root on the stack
    //we backtrack if we're pointing to the left
    //otherwise this functions like (id right)
    memcpy(saved.n, root.n, sizeof(Node));
    child_at_i(saved,2) = !side;
    stack_push(bt_stack, root, saved, side == 0);
#if OPT_EPOCH_TRAIL
    // A genuine choice point either way -- side == 0 is the first
    // exploration (the frame just pushed is choice-marked, i.e. a real
    // undo() stopping point); side == 1 is the second, dispatched only
    // after undo() already popped back to here and flipped it (that
    // frame isn't choice-marked, since there's nothing left to retry once
    // *this* alternative is also exhausted -- see undo()'s own doc
    // comment). Both still mark "everything from here on is younger than
    // this choice point" equally, so both advance current_epoch the same
    // way; stack_push above already captured the pre-increment value into
    // this frame regardless of which case this is.
    current_epoch++;
#endif

    // If this node is pointing to the right, then
    // we won't do any more backtracking,
    // but this node could be restored to the origonal choice later,
    // so any node that depends on it should be on the stack.
    set_forward(root,choices[side]);
    root.n->nondet = true;

    debug(HIGH, "leaving choice\n");
}

// Backtrack until we find a choice at or above stack height `cutoff`,
// overwriting every popped frame's lhs with its saved rhs along the way so
// the next attempt recomputes from the restored state. Returns true if a
// choice was found and (only in that case) left ready to try its other
// alternative; false means backtracking ran out of stack down to `cutoff`
// without finding one -- an ordinary top-level search passes cutoff 0, so
// this only reports "no solution at all"; a scoped caller (see
// OPT_SCOPED_BACKTRACK in prelude.c's lazy_unify_step) passes a height it
// recorded before starting, so this reports "no solution *in that scope*"
// without searching any choice point older than it, and every alternative
// within the scope still gets tried exactly as thoroughly either way --
// see backtracking-optimizations.md's #3 for why that's sound generally,
// not just for the one caller that originally used it.
bool undo(int cutoff)
{
    // Nothing above `cutoff` means nothing in scope. The loop below always
    // pops at least once, so without this check a scoped caller with an
    // empty scope (e.g. a function whose logical parent pushed a frame
    // before tail-dispatching into it) would pop and restore a frame that
    // belongs to an ancestor. For cutoff 0 this is the old size == 0 test.
    if(bt_stack->size <= (size_t)cutoff)
        return false;

    debug(HIGH, "full stack\n");
    debug_stack(HIGH);
    debug(HIGH, "undoing\n");
    FieldPair* frame;
    do
    {
        frame = pop(bt_stack);
        if(frame->lhs.n != NULL)
        {
            memcpy(frame->lhs.n, frame->rhs.n, sizeof(Node));
        }
    } while(!frame->choice && size(bt_stack) > cutoff);

    debug(HIGH, "finished undoing\n");
    debug_stack(HIGH);
    return frame->choice;
}

///////////////////////////////////////////////////////////////////////////
// Printing code for expressions and debugging
///////////////////////////////////////////////////////////////////////////


void print_frame(FieldPair* f)
{
    printf("%p:", f->lhs.n);
    print_expr(f->lhs);
    if(f->choice)
        printf(" T-> ");
    else
        printf(" F-> ");

    printf("%p:", f->rhs.n);
    print_expr(f->rhs);
}

void print_stack(Stack* s)
{
    printf("stacksize: %zu %zu\n", s->size, s->capacity);
    if(s->size == 0)
    {
        printf("[]\n");
        return;
    }
    for(int i = s->size - 1; i > 0; i--)
    {
        print_frame(&s->array[i]);
        printf(", \n");
    }
    print_frame(&s->array[0]);
    printf("\n");
}

static void print_raw(union field v, FieldRep r);

// Prints child i of n: a raw child by value (its rep says which
// primitive), a pointer child as an expression.
static void print_child_expr(union field n, int i)
{
    FieldRep r = child_rep(n.n->symbol, i);
    if(r == R_PTR)
        print_expr(child_at_v(n, i));
    else
        print_raw(child_at_v(n, i), r);
}

void print_expr(union field n)
{
    if(n.n == NULL)
    {
        printf("NULL");
        fflush(stdout);
        return;
    }
    fflush(stdout);
    printf("%s", n.n->symbol->name);
    fflush(stdout);
    if(n.n->nondet)
    {
        printf("?");
        fflush(stdout);
    }
    if(n.n->missing < 0) // this is only ever true in a PART symbol
    {
        printf("(");
        fflush(stdout);
        print_expr(child_at(n,0));
        printf(": ");
        fflush(stdout);
        for(int i = -n.n->missing; i > 1; i--)
        {
            print_expr(child_at_v(n,i));
            printf(", ");
            fflush(stdout);
        }
        print_expr(child_at(n,1));
        printf(")");
        fflush(stdout);
    }
    else if(n.n->symbol->arity)
    {
        // Children in storage order; a partial application's unfilled
        // slots show as `*`.
        int filled = filled_arity(n);
        printf("(");
        for(int i = 0; i < (int)n.n->symbol->arity; i++)
        {
            if(i > 0)
                printf(", ");
            if(i < filled)
                print_child_expr(n, i);
            else
                printf("*");
        }
        printf(")");
        fflush(stdout);
    }
}

// Prints components 0..i, comma-separated, in that (forward-storage,
// same convention as print_list/print_string above) order -- no parens;
// callers (print_final, below) print those themselves, both because
// they're the ones who already know to print the opening one before
// calling this, and because this used to fold the closing paren into its
// own i==0 base case, which -- paired with printing the *current* index
// before recursing to i-1, i.e. arity-1 first, down to 0 last -- printed
// every tuple starting from its last component instead of its first.
void print_tuple(union field n, int i)
{
    if(i == 0)
    {
        print_final(child_at(n,0));
    }
    else
    {
        print_tuple(n,i-1);
        printf(", ");
        print_final(child_at_v(n,i));
    }
}

// Appends c's *derived-Show* escaped spelling to buf (which must have
// room for at least 4 more bytes: the longest single-character
// expansion, a decimal escape like "\127", is 4 bytes) and returns the
// new write position. `quote` is whichever of '\'' or '"' is the
// enclosing literal's own delimiter -- the one character that needs
// escaping in one context but not the other (a bare '"' is fine inside
// 'x', a bare '\'' is fine inside "..."; confirmed against real kics2's
// own `show` output for exactly this case). Named escapes match GHC's
// derived Show (\a\b\f\n\r\t\v, plus \\ and the delimiter itself);
// anything else non-printable (code < 32, or >= 127 for a plain 7-bit
// char) falls back to a decimal escape, same convention. Lives here,
// not prelude.c, because runtime.c's own printing uses it and the
// runtime library (runtime/Makefile) doesn't include prelude.c.
char* appendEscaped(char* buf, char c, char quote)
{
    if (c == '\\')       { *buf++ = '\\'; *buf++ = '\\'; }
    else if (c == quote) { *buf++ = '\\'; *buf++ = quote; }
    else if (c == '\a')  { *buf++ = '\\'; *buf++ = 'a'; }
    else if (c == '\b')  { *buf++ = '\\'; *buf++ = 'b'; }
    else if (c == '\f')  { *buf++ = '\\'; *buf++ = 'f'; }
    else if (c == '\n')  { *buf++ = '\\'; *buf++ = 'n'; }
    else if (c == '\r')  { *buf++ = '\\'; *buf++ = 'r'; }
    else if (c == '\t')  { *buf++ = '\\'; *buf++ = 't'; }
    else if (c == '\v')  { *buf++ = '\\'; *buf++ = 'v'; }
    else if (c < 32 || c >= 127)
    {
        buf += sprintf(buf, "\\%d", (int)(unsigned char)c);
    }
    else { *buf++ = c; }
    return buf;
}

// (:)'s children are forward-stored like every other ordinary
// constructor (Rice.Codegen.C.ToH's setRealChildren): child 0 is the
// head (`:`'s first parameter), child 1 the tail (its second) -- *not*
// the reversed convention `apply`'s own missing-argument slots use
// (runtime.h's own note on that). These two functions (along with
// print_final's own "is this a char list" check right below) read them
// backwards -- a real, previously-uncaught bug: nothing before
// tests/run.sh's crash-detection fix (STATUS.md) had ever actually
// printed a list or string as `main`'s own top-level result (`putStr`'s
// own string handling, toCStr/toCurryString in prelude.c, was already
// correct and unaffected, since those never went through here).
// Derived-Show output, same convention as prim_showStringLiteral
// (prelude.c) -- this is nf_all's own top-level "print a found
// solution" path, a separate printer from show*Literal (only reached
// when a Curry program calls `show` itself), so it needs the exact
// same escaping independently: previously this just wrote each raw
// byte between quotes, so e.g. a string containing an actual newline
// or a literal backslash printed unescaped instead of as `\n`/`\\`.
static void printEscapedChar(char c, char quote);

// Prints a raw value the way Curry would show a literal of its type.
static void print_raw(union field v, FieldRep r)
{
    switch(r)
    {
        case R_INT:
            printf("%ld", v.i);
            break;
        case R_CHAR:
            printf("'");
            printEscapedChar((char)v.c, '\'');
            printf("'");
            break;
        case R_FLOAT:
            printf("%lf", v.f);
            break;
        case R_PTR:
            // Not a raw value; callers check the rep first.
            printf("<ptr %p>", (void*)v.n);
            break;
    }
}

void print_field(union field v, FieldRep r)
{
    if(r == R_PTR)
        print_expr(v);
    else
        print_raw(v, r);
}

static void printEscapedChar(char c, char quote)
{
    char buf[5];
    *appendEscaped(buf, c, quote) = '\0';
    printf("%s", buf);
}

void print_string(union field n)
{
    union field h = child_at(n,0);
    union field t = child_at(n,1);
    printf("\"");
    printEscapedChar((char)h.n->children[0].c, '"');
    while(strcmp(t.n->symbol->name, "[]"))
    {
        if(TAG(t) == FORWARD_TAG)
        {
            t = child_at(t,0);
        }
        else
        {
            h = child_at(t,0);
            t = child_at(t,1);
            printEscapedChar((char)h.n->children[0].c, '"');
        }
    }
    printf("\"");
    return;
}
void print_list(union field n)
{
    union field h = child_at(n,0);
    union field t = child_at(n,1);
    printf("[");
    print_final(h);
    while(strcmp(t.n->symbol->name, "[]"))
    {
        if(TAG(t) == FORWARD_TAG)
        {
            t = child_at(t,0);
        }
        else
        {
            h = child_at(t,0);
            t = child_at(t,1);
            printf(", ");
            print_final(h);
        }
    }
    printf("]");
    return;
}

void print_final(union field n)
{
    if(TAG(n) == FORWARD_TAG)
    {
        print_final(child_at_v(n,0));
        return;
    }
    if(!strcmp(n.n->symbol->name, ":"))
    {
        // children[0] is the head (forward storage, see print_string/
        // print_list's own note above) -- a `String` is `[Prelude.Char]`,
        // so checking its constructor's real, exact name ("Char", the
        // boxed Prelude constructor `toCurryString` builds every list
        // element out of -- prelude.c) is what actually distinguishes a
        // string from any other list; the lowercase "char" this checked
        // before never matched anything real either, independent of
        // which child it was reading.
        if(!strcmp(n.n->children[0].n->symbol->name, "Char"))
            print_string(n);
        else
            print_list(n);
        return;
    }
    if(!strcmp(n.n->symbol->name, "(,)"))               { printf("("); print_tuple(n,1);  printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,)"))              { printf("("); print_tuple(n,2);  printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,)"))             { printf("("); print_tuple(n,3);  printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,)"))            { printf("("); print_tuple(n,4);  printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,)"))           { printf("("); print_tuple(n,5);  printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,)"))          { printf("("); print_tuple(n,6);  printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,)"))         { printf("("); print_tuple(n,7);  printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,)"))        { printf("("); print_tuple(n,8);  printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,)"))       { printf("("); print_tuple(n,9);  printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,)"))      { printf("("); print_tuple(n,10); printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,,)"))     { printf("("); print_tuple(n,11); printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,,,)"))    { printf("("); print_tuple(n,12); printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,,,,)"))   { printf("("); print_tuple(n,13); printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,,,,,)"))  { printf("("); print_tuple(n,14); printf(")"); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,,,,,,)")) { printf("("); print_tuple(n,15); printf(")"); return; }
    // A box prints as its bare value (a Char as 'x', the derived-Show
    // convention print_string/showCharLiteral also follow).
    FieldRep box = box_rep(n.n->symbol);
    if(box != R_PTR)
    {
        print_raw(child_at(n,0), box);
        return;
    }
    printf("%s", n.n->symbol->name);
    if(n.n->symbol->arity)
    {
        // Children in storage order (forward: child 0 is the first
        // argument); a partial application's unfilled slots show as `*`.
        int filled = filled_arity(n);
        printf("(");
        for(int i = 0; i < (int)n.n->symbol->arity; i++)
        {
            if(i > 0)
                printf(", ");
            if(i >= filled)
                printf("*");
            else if(child_rep(n.n->symbol, i) == R_PTR)
                print_final(child_at_v(n,i));
            else
                print_raw(child_at_v(n,i), child_rep(n.n->symbol, i));
        }
        printf(")");
    }
}

// Whether p plausibly points at a node: past the unmapped first page,
// aligned like any allocation, and with a plausible symbol pointer of its
// own. A raw Int/Char/Float in a pointer slot almost always fails the
// first two tests before the third has to dereference anything.
static bool looks_like_node(union field p)
{
    uintptr_t a = (uintptr_t)p.n;
    if(a < 4096 || a % sizeof(void*) != 0)
        return false;
    uintptr_t s = (uintptr_t)p.n->symbol;
    return s >= 4096 && s % sizeof(void*) == 0;
}

void check_layout(union field n, bool allow_null, const char* where)
{
    Symbol* sym = n.n->symbol;
    int filled = filled_arity(n);
    for(int i = 0; i < filled; i++)
    {
        if(child_rep(sym, i) != R_PTR)
            continue;
        union field c = child_at_v(n, i);
        if(c.n == NULL ? allow_null : looks_like_node(c))
            continue;
        fprintf(stderr, "Error: layout check failed in %s: child %d of %s "
                        "should be a node pointer (R_PTR) but holds %#lx\n",
                where, i, sym->name, (unsigned long)c.i);
        exit(1);
    }
}

//////////////////////////////////////////////////////////////////////////////
// normal forms
//////////////////////////////////////////////////////////////////////////////
void error(char* msg, union field n)
{
    printf("Error: %s\n", msg);
    print_expr(n);
    exit(1);
}

// Normal forms on the evaluation machine: nf (every reachable value
// evaluated) and ground_nf (also fails on a free variable). Both are one
// routine, nfx_k, with frame [expr, settled, state, mode]:
//   expr     the node the caller holds. Failures are recorded on it, never
//            on `settled`: nf_all reads TAG(expr) directly, so a failure
//            left on a node further down a FORWARD chain would print as a
//            bogus solution.
//   settled  expr with FORWARD_TAG chased, evaluated to head normal form
//   state    -1 while settling; otherwise the index of the child being
//            normalized right now (children go last to first)
//   mode     0 for nf, 1 for ground_nf
// Each child gets its own frame, so depth follows the data on the machine
// stack, not the C stack. nf and ground_nf below are C drivers for it.
static const unsigned char nfx_reps[] = { R_PTR, R_PTR, R_INT, R_INT };
static RICE_CC void nfx_k(void);
static const FrameInfo nfx_info =
    { .code = nfx_k, .size = 4, .reps = nfx_reps, .name = "nf" };

static inline void nfx_push(union field expr, bool ground)
{
    frame_push(&nfx_info);
    SLOT(0) = expr;
    SLOT(1) = expr;
    SLOT(2).i = -1;
    SLOT(3).i = ground;
}

static RICE_CC void nfx_k(void)
{
    union field expr    = SLOT(0);
    union field settled = SLOT(1);
    long        state   = SLOT(2).i;
    bool        ground  = SLOT(3).i;

    if(state == -1)
    {
        debug(LOW, "solving: ");
        debug_expr(LOW, expr);
        while(true)
        {
            unsigned char t = TAG(settled);
            if(t == CHOICE_TAG || (t == FUNCTION_TAG && settled.n->missing <= 0))
            {
                SLOT(1) = settled;
                rice_root = settled;
                MUSTTAIL return settled.n->symbol->hnf();
            }
            if(t != FORWARD_TAG)
                break;
            settled = child_at(settled, 0);
        }
        SLOT(1) = settled;
        if(TAG(settled) == FAIL_TAG)
        {
            frame_pop();
            fail_nf(settled, expr);
            RETURN();
        }
        if(ground && TAG(settled) == FREE_TAG)
        {
            frame_pop();
            fail(expr);
            RETURN();
        }
        debug(LOW, "HNF: ");
        debug_expr(LOW, settled);
#if CHECK_LAYOUT
        check_layout(settled, false, ground ? "ground_nf" : "nf");
#endif
        state = filled_arity(settled);
    }
    else
    {
        // Child `state` has just been normalized.
        union field e = child_at_v(settled, state);
        if(TAG(e) == FAIL_TAG)
        {
            if(ground)
            {
                // ground_nf marks expr failed and goes on with the rest.
                fail(expr);
            }
            else
            {
                frame_pop();
                fail_nf(e, expr);
                RETURN();
            }
        }
    }

    // Next child to normalize: pointer children only (raw ones are values
    // already); ground_nf also skips an empty slot.
    for(long i = state - 1; i >= 0; i--)
    {
        if(child_rep(settled.n->symbol, (int)i) != R_PTR)
            continue;
        union field e = child_at_v(settled, i);
        if(ground && e.n == NULL)
            continue;
        SLOT(2).i = i;
        nfx_push(e, ground);
        MUSTTAIL return nfx_k();
    }
    frame_pop();
    RETURN();
}

static RICE_CC void nf_code(void)
{
    nfx_push(rice_root, false);
    MUSTTAIL return nfx_k();
}

static RICE_CC void ground_nf_code(void)
{
    nfx_push(rice_root, true);
    MUSTTAIL return nfx_k();
}

// Reduce expr to normal form. If any reachable value fails, expr fails.
void nf(union field expr)
{
    machine_run(nf_code, expr);
}

// Reduce expr to ground normal form: like nf, but a free variable
// anywhere fails expr too.
void ground_nf(union field expr)
{
    machine_run(ground_nf_code, expr);
}

// Runs `expr` (a standalone program's `main`, always `IO _`) to normal
// form exactly once: no "try another solution" backtracking loop, and no
// printing of the result itself -- an IO action's output is whatever side
// effects it already performed (putStrLn, etc.), not a value to show.
// This is what an ordinary compiled executable's C `main()` should do;
// `nf_all` below (compiled in when `rice --interactive` is given, e.g. by
// a curry-repl-style front end evaluating an arbitrary, possibly
// non-`IO`, possibly nondeterministic goal expression) is a different,
// heavier driver, not the right default for a plain `curry foo.curry`
// program. See Rice.Codegen.C.ToC.writeMain / Rice.Main's --interactive.
void run_io(union field expr)
{
    nf(expr);
    if(TAG(expr) == FAIL_TAG)
    {
        fprintf(stderr, "Program failed.\n");
        exit(1);
    }
}

// computer expr to a normal form, and print all solutions by backtracking.
void nf_all(union field expr)
{
    bool solution = false;
    nf(expr);
    debug(HIGH, "MAYBE SOLUTION 1: ");
    debug_expr(HIGH, expr);
    debug(HIGH, "%d = %d?\n", TAG(expr), FAIL_TAG);
    debug_stack(MED);
    if(TAG(expr) != FAIL_TAG)
    {
        printf("SOLUTION: ");
        print_final(expr);
        printf("\n");
        solution = true;
    }
    // While we can backtrack, try again.
    // The cutoff here is just the empty stack.
    while(undo(0))
    {
        debug(HIGH, "NORMALIZING %p:", expr.n);
        debug_expr(HIGH, expr);
        debug(HIGH, "\n");
        nf(expr);
        if(TAG(expr) != FAIL_TAG)
        {
            printf("SOLUTION: ");
            print_final(expr);
            printf("\n");
            solution = true;
            //print_stack(bt_stack);
        }
        //printf("stack size: %zu\n", bt_stack->size);
    }
    if(!solution)
    {
        printf("No solutions found\n");
    }
    printf("total memory allocations: %ld\n", mem);
}


// ----------------------------------------------------------------------
// Machine entry points (runtime/machine.h). Each runs its C-convention
// implementation above, which may still evaluate subterms with nested
// eval_hnf calls, then returns to the frame on top of the machine stack.
// ----------------------------------------------------------------------

RICE_CC void CTR_hnf(void) { CTR_impl(); RETURN(); }
RICE_CC void choice_hnf(void) { choice_impl(); RETURN(); }
RICE_CC void forward_hnf(void) { forward_impl(); RETURN(); }
