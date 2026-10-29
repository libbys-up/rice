#include<stdbool.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>
#include<stdint.h>
#include<math.h>
#include "runtime.h"

#include "node.h"
#include "trail.h"
#include "debug.h"

// Note:
// (void)var;
// is used to suppress variable not used warnings, so we can use -Wall.

// This is for epoch trailing, see runtime.h.
// Unlike trail and mem, this is defined here instead of in the generated main.c,
// because nothing about it is specific to one program.
unsigned int current_epoch = 0;

#if OPT_STATS
OptStats opt_stats;
#endif

// Print the OPT_STATS counters to stderr (one `name value` per line,
// for tests/optbench.sh). A no-op without OPT_STATS.
void print_opt_stats(void)
{
#if OPT_STATS
#define PRINT_STAT(name) fprintf(stderr, "stat %s %lu\n", #name, opt_stats.name)
    PRINT_STAT(trail_decisions);
    PRINT_STAT(trailed_rewrites);
    PRINT_STAT(skipped_nondet);
    PRINT_STAT(skipped_epoch);
    PRINT_STAT(barrier_lowered);
    PRINT_STAT(lowered_nodes);
    PRINT_STAT(lowered_rewritten);
    PRINT_STAT(lowered_rewrites);
    PRINT_STAT(lowered_trailed);
    PRINT_STAT(trail_pushes);
    PRINT_STAT(choice_points);
    PRINT_STAT(undos);
    PRINT_STAT(undo_restores);
    PRINT_STAT(scoped_retries);
    PRINT_STAT(scoped_hits);
    PRINT_STAT(copy_collapses);
    PRINT_STAT(forward_collapses);
    PRINT_STAT(forward_hops);
    PRINT_STAT(compressions);
    PRINT_STAT(compress_hops_skipped);
    PRINT_STAT(max_trail);
    PRINT_STAT(tail_calls);
    fprintf(stderr, "stat allocations %lu\n", mem);
#undef PRINT_STAT
#endif
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

/* Sets free variable n to the constructor of `like`, with a fresh free
 * variable for every pointer child.  This is the core of a narrowing step.
 * A raw child can't be a free variable (a raw slot has no node to bind later),
 * so it takes `like`'s own value instead.
 */
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
        n.n->children[3].a = alloc_spill(sym->arity - 3);
    }
    for(unsigned int i = 0; i < sym->arity; i++)
    {
        if(child_rep(sym, i) == R_PTR)
        {
            set_child_at(n, i, free_var());
        }
        else
        {
            set_child_at(n, i, child_at_v(like, i));
        }
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

/* Overwrite new_node with the contents of node.
 * The spill array gets copied too, so the two nodes don't share it.
 */
union field set_copy(union field new_node, union field node)
{
#if OPT_EPOCH_TRAIL
    // new_node keeps its own epoch.
    // We're overwriting its contents, not allocating it,
    // so it's just as old as it was before.
    // apply_hnf uses this to overwrite a long lived root,
    // and taking node's epoch would make root look young.
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
        new_node.n->children[3].a = alloc_spill(arity - 3);
        memcpy(new_node.n->children[3].a, node.n->children[3].a, size);
    }
    return new_node;
}

// create a copy of node.
union field copy(union field node)
{
    union field new;
    new.n = (Node*)alloc(sizeof(Node));
#if OPT_EPOCH_TRAIL
    // This is a fresh node, so it's stamped with the current epoch.
    // We do this before set_copy, because set_copy keeps the destination's epoch.
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
    (void)sym;
    (void)from;
    (void)count;
#endif
}

/* Reduce apply(f, x1, ..., xn) on the evaluation machine.
 * apply_hnf pushes a frame [root, f, nondet] and enters apply_k.
 * apply_k evaluates f until it's a partial application:
 * evaluating f jumps to f's code, which returns into apply_k.
 * Once f is a partial application, we pop the frame and fill in the arguments.
 * If that makes a fully applied call, we tail jump to it.
 */
static const unsigned char apply_reps[] = { R_PTR, R_PTR, R_INT };
static RICE_CC void apply_k(union field _root, Frame* sp);
static const FrameInfo apply_info =
    { .code = apply_k, .size = 3, .reps = apply_reps, .name = "apply" };

RICE_CC void apply_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    debug(LOW, "HNF apply: \n");
    debug_expr(LOW, root);
    sp = frame_push(sp, &apply_info);
    SLOT(0) = root;
    SLOT(1) = child_at(root, 0);
    SLOT(2).i = false;
    MUSTTAIL return apply_k(root, sp);
}

static RICE_CC void apply_k(union field _root, Frame* sp)
{
    (void)_root;
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
                sp = frame_pop(sp);
                (void)push_node(root,nondet);
                fail(root);
                RETURN();

            case FUNCTION_TAG:
                debug(HIGH, "apply FUNCTION\n");
                // f must be fully applied, or we would have left the loop!
                SLOT(1) = f;
                SLOT(2).i = nondet;
                MUSTTAIL return f.n->symbol->hnf(f, sp);

            case CHOICE_TAG:
                debug(HIGH, "apply CHOICE\n");
                choose(f);
                break;

            case FORWARD_TAG:
                debug(HIGH, "apply FORWARD\n");
                f = follow_forward(f);
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
    sp = frame_pop(sp);

    union field child1 = root.n->children[1];
    union field child2 = root.n->children[2];
    union field* array = root.n->children[3].a;

    // Now we're guaranteed to have a partial application
    debug(HIGH, "apply PART\n");

    nondet |= f.n->nondet;

    nondet = push_node(root,nondet);

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
        // set_copy took f's flag, but root's has to cover everything this
        // rewrite read (the forwards on the way to f too), and stay sticky.
        root.n->nondet = nondet;

        // f's node stores its arguments forward,
        // with the missing ones in its last `missing` slots.
        // So the first empty slot is arity - missing, and we fill upward from there.
        // The apply node stores its arguments in reverse (see runtime.h),
        // so the first argument we fill in is child1, the last one in the apply node.
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
            // root is now a fully applied call: reduce it with a tail
            // jump, which returns wherever apply would have.
            MUSTTAIL return root.n->symbol->hnf(root, sp);
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
#if OPT_WRITE_BARRIER
        // newf is a call built for root's new value (runtime.h's rewrite_stamp).
        newf.n->epoch = rewrite_stamp(root);
#endif
        debug_expr(LOW, newf);

        // copy arguments.
        // Same as above: fill newf's missing slots from the first empty one upward.
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
        // newf is a fully applied call. We don't evaluate it here:
        // the apply node we build next evaluates it as its function.
        child_at(root,0) = newf;
        root.n->missing = -nargs;
        debug(HIGH, "new apply node\n");
        debug_expr(HIGH, root);

        // We're still overapplied so try again
        MUSTTAIL return apply_hnf(root, sp);
    }
}



//////////////////////////////////////////////////////////////////////////////
// code for backtracking
//////////////////////////////////////////////////////////////////////////////

// push (node -> copy(node)) on the trail, leaving node itself unchanged.
// A whole-node memcpy, so the snapshot keeps node's own epoch and nondet
// flag, and undo() puts both back.
void save_snapshot(union field node)
{
    union field saved;
    saved.n = (Node*)alloc(sizeof(Node));
    memcpy(saved.n, node.n, sizeof(Node));
    trail_push(trail, node, saved, false);
}

// save_snapshot, then mark node nondet. Always trails: used where the
// trail is unconditional (free-variable bindings, fail_nf). Rewrites of a
// node with its own reduct go through trail_node (runtime.h) instead.
void save_copy(union field node)
{
    save_snapshot(node);
    node.n->nondet = true;
}

// push (n -> saved) on the trail
void save(union field n, union field saved)
{
    debug(HIGH, "save: ");
    debug_expr(HIGH, n);
    debug_expr(HIGH, saved);
    n.n->nondet = true;
    trail_push(trail, n, saved, false);
}

// push (left -> right) on the trail, as an ordinary (non-choice) entry.
// Narrowing uses this: the generated code for a FREE scrutinee
// pushes (scrutinee -> fresh free variable),
// so once every constructor has been tried, the variable is free again.
void push_frame(union field left, union field right)
{
    trail_push(trail, left, right, false);
}

// push (left ->? right) on the trail.
// This is the stopping point while backtracking.
// Narrowing uses this for each other constructor a free variable could be.
// Like choose(), this is a choice point, so it advances current_epoch (#5).
// trail_push saves the old epoch in the entry first,
// so everything allocated after this looks younger than the choice point.
void push_choice(union field left, union field right)
{
    trail_push(trail, left, right, true);
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
// Both sides mark root nondet and trail it: a choice is nondeterministic
// even in its last alternative (backtracking_proofs.md, nondet tracking rule 4).
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
    //make a copy of root to push on the trail
    //swap if we're using left/right node
    //push root on the trail
    //we backtrack if we're pointing to the left
    //otherwise this functions like (id right)
    memcpy(saved.n, root.n, sizeof(Node));
    child_at_i(saved,2) = !side;
    trail_push(trail, root, saved, side == 0);
#if OPT_EPOCH_TRAIL
    // Both sides count as a choice point for epochs.
    // Only the left side's entry is a choice entry for undo(),
    // because after the right side there's nothing left to try,
    // but everything allocated from here on is still younger than this choice.
    current_epoch++;
#endif

    // If this node is pointing to the right, then
    // we won't do any more backtracking,
    // but this node could be restored to the original choice later,
    // so any node that depends on it should be on the trail.
    set_forward(root,choices[side]);
    root.n->nondet = true;

    debug(HIGH, "leaving choice\n");
}

/* Backtrack until we find a choice at or above trail height `cutoff`.
 * Every entry we pop gets restored (rhs is copied back over lhs),
 * so the next attempt starts from the restored graph.
 * Returns true if we found a choice, and it's ready to try its other alternative.
 * Returns false if we ran out of trail down to `cutoff` without finding one.
 *
 * Top level search passes cutoff 0, so false means "no more solutions".
 * Scoped backtracking (#3) passes the height from when its function started,
 * so false means "no more solutions in this scope",
 * and we never touch choices older than that.
 */
bool undo(int cutoff)
{
    // Nothing above `cutoff` means nothing in scope.
    // The loop below always pops at least once,
    // so without this check we'd pop an entry that belongs to someone else.
    if(trail->size <= (size_t)cutoff)
    {
        return false;
    }

    debug(HIGH, "full trail\n");
    debug_trail(HIGH);
    debug(HIGH, "undoing\n");
    STAT(undos);
    TrailEntry* frame;
    do
    {
        frame = trail_pop(trail);
        STAT(undo_restores);
        if(frame->lhs.n != NULL)
        {
            memcpy(frame->lhs.n, frame->rhs.n, sizeof(Node));
        }
    } while(!frame->choice && trail_size(trail) > cutoff);

    debug(HIGH, "finished undoing\n");
    debug_trail(HIGH);
    return frame->choice;
}

///////////////////////////////////////////////////////////////////////////
// Printing code for expressions and debugging
///////////////////////////////////////////////////////////////////////////


void print_trail_entry(TrailEntry* f)
{
    printf("%p:", f->lhs.n);
    print_expr(f->lhs);
    if(f->choice)
    {
        printf(" T-> ");
    }
    else
    {
        printf(" F-> ");
    }

    printf("%p:", f->rhs.n);
    print_expr(f->rhs);
}

void print_trail(Trail* s)
{
    printf("trail size: %zu %zu\n", s->size, s->capacity);
    if(s->size == 0)
    {
        printf("[]\n");
        return;
    }
    for(int i = s->size - 1; i > 0; i--)
    {
        print_trail_entry(&s->array[i]);
        printf(", \n");
    }
    print_trail_entry(&s->array[0]);
    printf("\n");
}

static void print_raw(union field v, FieldRep r);

// Prints child i of n: a raw child by value (its rep says which
// primitive), a pointer child as an expression.
static void print_child_expr(union field n, int i)
{
    FieldRep r = child_rep(n.n->symbol, i);
    if(r == R_PTR)
    {
        print_expr(child_at_v(n, i));
    }
    else
    {
        print_raw(child_at_v(n, i), r);
    }
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
    if(n.n->missing < 0) // an apply node: the function, then the arguments
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
            {
                printf(", ");
            }
            if(i < filled)
            {
                print_child_expr(n, i);
            }
            else
            {
                printf("*");
            }
        }
        printf(")");
        fflush(stdout);
    }
}

// Prints components 0..i of a tuple, separated by commas.
// The caller prints the parentheses.
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

/* Appends c, escaped the way Curry's derived Show would, to buf,
 * and returns the new write position.
 * buf needs room for at least 4 more bytes (the longest escape is "\127").
 * `quote` is the delimiter of the literal we're in ('\'' or '"').
 * That's the one character that only needs escaping in one context:
 * a bare '"' is fine inside 'x', and a bare '\'' is fine inside "...".
 * Named escapes match GHC's derived Show (\a \b \f \n \r \t \v, \\, and the delimiter).
 * Anything else that isn't printable gets a decimal escape.
 * This lives here instead of ext/Prelude.c because the runtime library
 * (runtime/Makefile) doesn't include ext/Prelude.c, and our printing needs it.
 */
char* appendEscaped(char* buf, char c, char quote)
{
    if(c == '\\')
    {
        *buf++ = '\\';
        *buf++ = '\\';
    }
    else if(c == quote)
    {
        *buf++ = '\\';
        *buf++ = quote;
    }
    else if(c == '\a')
    {
        *buf++ = '\\';
        *buf++ = 'a';
    }
    else if(c == '\b')
    {
        *buf++ = '\\';
        *buf++ = 'b';
    }
    else if(c == '\f')
    {
        *buf++ = '\\';
        *buf++ = 'f';
    }
    else if(c == '\n')
    {
        *buf++ = '\\';
        *buf++ = 'n';
    }
    else if(c == '\r')
    {
        *buf++ = '\\';
        *buf++ = 'r';
    }
    else if(c == '\t')
    {
        *buf++ = '\\';
        *buf++ = 't';
    }
    else if(c == '\v')
    {
        *buf++ = '\\';
        *buf++ = 'v';
    }
    else if(c < 32 || c >= 127)
    {
        buf += sprintf(buf, "\\%d", (int)(unsigned char)c);
    }
    else
    {
        *buf++ = c;
    }
    return buf;
}

// Print one character of a Char or String literal, escaped like derived Show.
static void printEscapedChar(char c, char quote);

/* Writes x into buf (at least 32 bytes) the way Curry (and Haskell) show a
 * Float: the fewest digits that read back as exactly x, in decimal notation
 * from 0.1 up to 10^7 (0.1, 3.5, 7.0) and in scientific notation outside
 * that (1.0e-2, 1.0e7).
 * KiCS2 shows floats this way, and so must we: generated C writes float
 * literals with show, so a lossy show would change a compiled program's
 * constants.
 */
void showFloat(char* buf, double x)
{
    if(isnan(x))
    {
        strcpy(buf, "NaN");
        return;
    }
    if(isinf(x))
    {
        strcpy(buf, x > 0 ? "Infinity" : "-Infinity");
        return;
    }
    char* out = buf;
    if(signbit(x))
    {
        *out++ = '-';
        x = -x;
    }
    if(x == 0)
    {
        strcpy(out, "0.0");
        return;
    }
    // The shortest %e form that reads back as x: "d.ddde+XX".
    char e_form[32];
    for(int prec = 0; prec < 17; prec++)
    {
        snprintf(e_form, sizeof e_form, "%.*e", prec, x);
        if(strtod(e_form, NULL) == x)
        {
            break;
        }
    }
    // Its digits, without the point or trailing zeros, and its exponent,
    // with x = 0.digits * 10^exp.
    char digits[24];
    int nd = 0;
    char* p = e_form;
    for(; *p != 'e'; p++)
    {
        if(*p != '.')
        {
            digits[nd++] = *p;
        }
    }
    while(nd > 1 && digits[nd - 1] == '0')
    {
        nd--;
    }
    digits[nd] = '\0';
    int exp = atoi(p + 1) + 1;
    if(x >= 0.1 && x < 1e7)
    {
        if(exp <= 0)
        {
            out += sprintf(out, "0.");
            for(int i = 0; i < -exp; i++)
            {
                *out++ = '0';
            }
            strcpy(out, digits);
        }
        else if(nd <= exp)
        {
            out += sprintf(out, "%s", digits);
            for(int i = nd; i < exp; i++)
            {
                *out++ = '0';
            }
            strcpy(out, ".0");
        }
        else
        {
            out += sprintf(out, "%.*s.%s", exp, digits, digits + exp);
        }
    }
    else
    {
        sprintf(out, "%c.%se%d", digits[0], nd > 1 ? digits + 1 : "0", exp - 1);
    }
}

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
        {
            char buf[32];
            showFloat(buf, v.f);
            printf("%s", buf);
            break;
        }
        case R_PTR:
            // Not a raw value; callers check the rep first.
            printf("<ptr %p>", (void*)v.n);
            break;
    }
}

void print_field(union field v, FieldRep r)
{
    if(r == R_PTR)
    {
        print_expr(v);
    }
    else
    {
        print_raw(v, r);
    }
}

static void printEscapedChar(char c, char quote)
{
    char buf[5];
    *appendEscaped(buf, c, quote) = '\0';
    printf("%s", buf);
}

// Print a String (a list of boxed Chars) as a string literal.
// (:) stores its children forward, like every constructor:
// child 0 is the head, and child 1 is the tail.
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

// If name is a tuple constructor "(,)", "(,,)", ..., return its number of commas.
// Otherwise return 0.
static int tuple_commas(const char* name)
{
    if(name[0] != '(' || name[1] != ',')
    {
        return 0;
    }
    int commas = 0;
    const char* p = name + 1;
    while(*p == ',')
    {
        commas++;
        p++;
    }
    if(p[0] != ')' || p[1] != '\0')
    {
        return 0;
    }
    return commas;
}

// Print a fully evaluated value, for showing the solutions nf_all finds.
void print_final(union field n)
{
    if(TAG(n) == FORWARD_TAG)
    {
        print_final(child_at_v(n,0));
        return;
    }
    if(!strcmp(n.n->symbol->name, ":"))
    {
        // A String is a [Char], so we can tell a string from any other list
        // by checking whether the head is a boxed Char.
        if(!strcmp(n.n->children[0].n->symbol->name, "Char"))
        {
            print_string(n);
        }
        else
        {
            print_list(n);
        }
        return;
    }
    int commas = tuple_commas(n.n->symbol->name);
    if(commas > 0)
    {
        printf("(");
        print_tuple(n, commas);
        printf(")");
        return;
    }
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
            {
                printf(", ");
            }
            if(i >= filled)
            {
                printf("*");
            }
            else if(child_rep(n.n->symbol, i) == R_PTR)
            {
                print_final(child_at_v(n,i));
            }
            else
            {
                print_raw(child_at_v(n,i), child_rep(n.n->symbol, i));
            }
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
    {
        return false;
    }
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
        {
            continue;
        }
        union field c = child_at_v(n, i);
        bool ok;
        if(c.n == NULL)
        {
            ok = allow_null;
        }
        else
        {
            ok = looks_like_node(c);
        }
        if(ok)
        {
            continue;
        }
        fprintf(stderr, "Error: layout check failed in %s: child %d of %s "
                        "should be a node pointer (R_PTR) but holds %#lx\n",
                where, i, sym->name, (unsigned long)c.i);
        exit(1);
    }
}

//////////////////////////////////////////////////////////////////////////////
// normal forms
//////////////////////////////////////////////////////////////////////////////
// The program's output so far comes first, then the message, on stderr.
void error(char* msg, union field n)
{
    fflush(stdout);
    fprintf(stderr, "Error: %s\n", msg);
    print_expr(n);
    exit(1);
}

/* Normal forms on the evaluation machine: nf (every reachable value
 * evaluated) and ground_nf (also fails on a free variable). Both are one
 * routine, nfx_k, with frame [expr, settled, state, mode]:
 *   expr     the node the caller holds. Failures are recorded on it, never
 *            on `settled`: nf_all reads TAG(expr) directly, so a failure
 *            left on a node further down a FORWARD chain would print as a
 *            bogus solution.
 *   settled  expr with FORWARD_TAG chased, evaluated to head normal form
 *   state    -1 while settling; otherwise the index of the child being
 *            normalized right now (children go last to first)
 *   mode     0 for nf, 1 for ground_nf
 * Each child gets its own frame, so depth follows the data on the machine
 * stack, not the C stack. nf and ground_nf below are C drivers for it.
 */
static const unsigned char nfx_reps[] = { R_PTR, R_PTR, R_INT, R_INT };
static RICE_CC void nfx_k(union field _root, Frame* sp);
static const FrameInfo nfx_info =
    { .code = nfx_k, .size = 4, .reps = nfx_reps, .name = "nf" };

static inline Frame* nfx_push(Frame* sp, union field expr, bool ground)
{
    sp = frame_push(sp, &nfx_info);
    SLOT(0) = expr;
    SLOT(1) = expr;
    SLOT(2).i = -1;
    SLOT(3).i = ground;
    return sp;
}

static RICE_CC void nfx_k(union field _root, Frame* sp)
{
    (void)_root;
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
                MUSTTAIL return settled.n->symbol->hnf(settled, sp);
            }
            if(t != FORWARD_TAG)
            {
                break;
            }
            settled = child_at(settled, 0);
        }
        SLOT(1) = settled;
        if(TAG(settled) == FAIL_TAG)
        {
            sp = frame_pop(sp);
            fail_nf(settled, expr);
            RETURN();
        }
        if(ground && TAG(settled) == FREE_TAG)
        {
            sp = frame_pop(sp);
            fail(expr);
            RETURN();
        }
        debug(LOW, "HNF: ");
        debug_expr(LOW, settled);
#if CHECK_LAYOUT
        if(ground)
        {
            check_layout(settled, false, "ground_nf");
        }
        else
        {
            check_layout(settled, false, "nf");
        }
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
                sp = frame_pop(sp);
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
        {
            continue;
        }
        union field e = child_at_v(settled, i);
        if(ground && e.n == NULL)
        {
            continue;
        }
        SLOT(2).i = i;
        sp = nfx_push(sp, e, ground);
        MUSTTAIL return nfx_k(e, sp);
    }
    sp = frame_pop(sp);
    RETURN();
}

static RICE_CC void nf_code(union field root, Frame* sp)
{
    sp = nfx_push(sp, root, false);
    MUSTTAIL return nfx_k(root, sp);
}

static RICE_CC void ground_nf_code(union field root, Frame* sp)
{
    sp = nfx_push(sp, root, true);
    MUSTTAIL return nfx_k(root, sp);
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

/* Run a compiled program's `main` (an IO action) to normal form once.
 * There's no "try another solution" loop, and we don't print the result:
 * an IO action's output is the side effects it already performed.
 * nf_all below is the other driver, for `rice --interactive`,
 * where the goal can be any expression and might have several solutions.
 * See Rice.Codegen.C.ToC.writeMain and Rice.Main's --interactive.
 */
void run_io(union field expr)
{
    GC_ROOT(expr);  // nf runs the machine
    nf(expr);
    GC_UNROOT(1);
    print_opt_stats();
    if(TAG(expr) == FAIL_TAG)
    {
        fflush(stdout);
        fprintf(stderr, "Program failed.\n");
        exit(1);
    }
}

// compute expr to a normal form, and print all solutions by backtracking.
void nf_all(union field expr)
{
    bool solution = false;
    // Every nf runs the machine; expr is the same root throughout.
    GC_ROOT(expr);
    nf(expr);
    debug(HIGH, "MAYBE SOLUTION 1: ");
    debug_expr(HIGH, expr);
    debug(HIGH, "%d = %d?\n", TAG(expr), FAIL_TAG);
    debug_trail(MED);
    if(TAG(expr) != FAIL_TAG)
    {
        printf("SOLUTION: ");
        print_final(expr);
        printf("\n");
        solution = true;
    }
    // While we can backtrack, try again.
    // The cutoff here is just the empty trail.
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
        }
    }
    GC_UNROOT(1);
    if(!solution)
    {
        printf("No solutions found\n");
    }
    // For tests/bench.sh, which reads the count from the program's output.
    if(getenv("RICE_ALLOC_STATS") != NULL)
    {
        fflush(stdout);
        fprintf(stderr, "total memory allocations: %ld\n", mem);
    }
    print_opt_stats();
}


// ----------------------------------------------------------------------
// Machine entry points (runtime/machine.h). Each runs its C-convention
// implementation above, then returns to the frame on top of the machine stack.
// ----------------------------------------------------------------------

RICE_CC void CTR_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    CTR_impl();
    RETURN();
}

RICE_CC void choice_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    rice_root = root;
    choice_impl();
    RETURN();
}

// A FORWARD node is already in head normal form, as far as hnf is concerned.
// Whoever evaluated it chases the forward themselves (see HNF in runtime.h).
RICE_CC void forward_hnf(union field root, Frame* sp)
{
    GC_SAFE_POINT(root, sp);
    (void)root;
    RETURN();
}

// A tail call with #2 off (OPT_TAIL_DISPATCH=0, TAIL_CALL in runtime.h).
// Instead of jumping to the callee's code, which the caller knows,
// we do what a trampoline's loop would do with the root it got back:
// check the tag, and if root still needs reducing, jump through its symbol.
// Root is always a FUNCTION or a CHOICE here, so the default case is only
// the check itself.
RICE_CC void redispatch(union field root, Frame* sp)
{
    switch(TAG(root))
    {
        case FUNCTION_TAG:
        case CHOICE_TAG:
            MUSTTAIL return root.n->symbol->hnf(root, sp);
        default:
            RETURN();
    }
}
