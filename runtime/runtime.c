#include<stdbool.h>
#include<stdio.h>
#include<stdlib.h>
#include<string.h>
#include "runtime.h"

#include "node.h"
#include "stack.h"
#include "debug.h"



void CTR_hnf(union field root)
{
    debug(LOW, "HNF constructor:");
    debug_expr(LOW, root);
}

void choice_hnf(union field root)
{
    debug(LOW, "HNF choice:");
    debug_expr(LOW, root);
    choose(root);
}

// sets a free varialbe.
void set_free_constructor(union field n, Symbol* sym)
{
    n.n->symbol = sym;
    n.n->missing = 0;
    n.n->nondet = true;
    n.n->children[0].n = NULL:
    n.n->children[1].n = NULL:
    n.n->children[2].n = NULL:
    n.n->children[3].a = NULL:
    if(sym->arity > 3)
    {
        n.n->children[3] = (union field*)malloc((sym->arity - 3) * sizeof(union field));
    }
    for(int i = 0; i < sym->arity; i++)
    {
        set_child_at(n, i, free_var())
    }
}

union field set_copy(union field new_node, union field node)
{
    memcpy(new_node.n, node.n, sizeof(Node));
    int arity = node.n->symbol->arity;
    int size = (arity-3)*sizeof(union field);
    if(arity > 3)
    {
        new_node.n->children[3].a = (union field*)alloc(size);
        memcpy(new_node.n->children[3].a, node.n->children[3].a, size);
    }
    return new_node;
}
union field set_copy_free(union field new_node, union field node)
{
    int arity = node.n->symbol->arity;

    new_node.n = (Node*)alloc(sizeof(Node));
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

union field copy(union field node)
{
    union field new;
    new.n = (Node*)alloc(sizeof(Node));
    set_copy(new, node);
    return new;
}

void apply_hnf(union field root)
{
    debug(LOW, "HNF apply: \n");
    debug_expr(LOW, root);
    union field f = child_at(root,0);
    union field child1 = root.n->children[1];
    union field child2 = root.n->children[2];
    union field* array = root.n->children[3].a;
    bool nondet = false;

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
                push_node(root,nondet);
                fail(root);
                return;
    
            case FUNCTION_TAG:
                debug(HIGH, "apply FUNCTION\n");
                // f must be fully applied, or we would have left the loop!
                HNF(f);
                break;
    
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
        } 
    }
    // Now we're guaranteed to have a partial application
    debug(HIGH, "apply PART\n");

    nondet |= f.n->nondet;

    push_node(root,nondet);

    // number of arguments that we're applying
    int nargs = -root.n->missing;

    //number of arguments we have left
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
        while(nargs > 2)
        {
            debug_expr(HIGH, array[nargs-3]);
            set_child_at(root, missing-1, array[nargs-3]);
            missing--;
            nargs--;
        }
        if(nargs > 1)
        {
            debug_expr(HIGH, child2);
            set_child_at(root,missing-1, child2);
            missing--;
        }

        // we have at least one node, or we wouldn't have an apply node.
        debug_expr(HIGH, child1);
        set_child_at(root,missing-1, child1);
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
            HNF(root);
        }
        debug(HIGH, "leaving apply\n");
        debug_expr(HIGH, root);
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

        // copy arguments
        while(missing > 0)
        {
            set_child_at(newf, missing-1, child_at_v(root, nargs));
            nargs--;
            missing--;
        }

        // reduce the fully applied function
        debug(HIGH, "fully applied child\n");
        debug_expr(HIGH, newf);
        newf.n->missing = 0;
        HNF(newf);
        debug(HIGH, "fully applied child reduced\n");
        debug_expr(HIGH, newf);

        // set root to be the reduced function, and update the number
        // of parameters missing.
        // This is why we store the parameters in reverse order.
        // We can just update missing to the number of args left!
        child_at(root,0) = newf;
        root.n->missing = -nargs;
        debug(HIGH, "new apply node\n");
        debug_expr(HIGH, root);

        // We're still overapplied so try again
        apply_hnf(root);
        debug(HIGH, "leaving apply\n");
        debug_expr(HIGH, root);
        return;
    }
}


void forward_hnf(union field root) {}

//////////////////////////////////////////////////////////////////////////////
// code for backtracking
//////////////////////////////////////////////////////////////////////////////

void save_copy(union field node)
{
    union field saved;
    saved.n = (Node*)alloc(sizeof(Node));
    memcpy(saved.n, node.n, sizeof(Node));
    node.n->nondet = true;
    stack_push(bt_stack, node, saved, false);
}

void save(union field n, union field saved)
{
    debug(HIGH, "save: ");
    debug_expr(HIGH, n);
    debug_expr(HIGH, saved);
    n.n->nondet = true;
    stack_push(bt_stack, n, saved, false);
}

void push_frame(union field left, union field right)
{
    stack_push(bt_stack, left, right, false);
}

//push a choice onto the backtrack stack
//This is our stopping condition for backtracking.
void push_choice(union field left, union field right)
{
    stack_push(bt_stack, left, right, true);
}

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

    // If this node is pointing to the right, then
    // we won't do any more backtracking,
    // but this node could be restored to the origonal choice later,
    // so any node that depends on it should be on the stack.
    set_forward(root,choices[side]);
    root.n->nondet = true;

    debug(HIGH, "leaving choice\n");
}

// backtrack until we find a choice.
// We overwrite all of the node in the stack
// with their saved values.
// Then we recompute the nodes with the new choice.
// Return true if we found a choice node.
//
// We're adding a cutoff point.
// This is only used for part 4 where we do early backtracking.
// otherwise we just do normal undo.
// If we're doing early backtracking, then stop at the cutoff and return false.
// This is an actual failure.
bool undo(int cutoff)
{
    if(bt_stack->size == 0)
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
            if(frame->choice)
            memcpy(frame->lhs.n, frame->rhs.n, sizeof(Node));
        }
#if TEST == 3
    } while(!frame->choice && size(bt_stack) > cutoff);
#else
    } while(!frame->choice && size(bt_stack) > 0);
#endif

    debug(HIGH, "finished undoing\n");
    debug_stack(HIGH);
    return frame->choice;
}

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
    printf("stacksize: %ld %ld\n", bt_stack->size, bt_stack->capacity);
    if(bt_stack->size == 0)
    {
        printf("[]\n");
        return;
    }
    for(int i = bt_stack->size; i > 0; i--)
    {
        print_frame(&bt_stack->array[i]);
        printf(", \n");
    }
    print_frame(&bt_stack->array[0]);
    printf("\n");
}

void print_expr(union field n)
{
    // n is probably an int or char
    if(n.i < 1000001)
    {
        printf("%ld", n.i);
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
    if(n.n->missing < 0) // this is only ever true in an apply symbol
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
        printf("(");
        fflush(stdout);
        if(child_at_i(n,1) == INT_CTR)
        {
            printf("%ld", child_at_i(n,0));
            fflush(stdout);
        }
        else if(child_at_i(n,1) == CHAR_CTR)
        {
            printf("%c", (char)child_at_c(n,0));
            fflush(stdout);
        }
        else if(child_at_i(n,1) == FLOAT_CTR)
        {
            printf("%lf", child_at_f(n,0));
            fflush(stdout);
        }
        else
        {
            for(int i = n.n->symbol->arity-1; i > 0; i--)
            {
                if(i >= n.n->missing)
                {
                    print_expr(child_at_v(n,i));
                    printf(", ");
                    fflush(stdout);
                }
                else
                {
                    printf("*, ");
                    fflush(stdout);
                }
            }
            if(n.n->missing == 0)
            {
                print_expr(child_at_v(n,0));
            }
            else
            {
                printf("*");
                fflush(stdout);
            }
        }
        printf(")");
        fflush(stdout);
    }
}

void print_tuple(union field n, int i)
{
    if(i == 0)
    {
        print_final(child_at(n,0));
        printf(")");
    }
    else
    {
        print_final(child_at_v(n,i));
        printf(", ");
        print_tuple(n,i-1);
    }
}

void print_string(union field n)
{
    union field h = child_at(n,1);
    union field t = child_at(n,0);
    printf("\"");
    printf("%c", (char)h.n->children[0].c);
    while(strcmp(t.n->symbol->name, "[]"))
    {
        if(TAG(t) == FORWARD_TAG)
        {
            t = child_at(t,0);
        }
        else
        {
            h = child_at(t,1);
            t = child_at(t,0);
            printf("%c", (char)h.n->children[0].c);
        }
    }
    printf("\"");
    return;
}
void print_list(union field n)
{
    union field h = child_at(n,1);
    union field t = child_at(n,0);
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
            h = child_at(t,1);
            t = child_at(t,0);
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
        if(!strcmp(n.n->children[1].n->symbol->name, "char"))
            print_string(n);
        else
            print_list(n);
        return;
    }
    if(!strcmp(n.n->symbol->name, "(,)"))               { printf("("); print_tuple(n,1);  return; }
    if(!strcmp(n.n->symbol->name, "(,,)"))              { printf("("); print_tuple(n,2);  return; }
    if(!strcmp(n.n->symbol->name, "(,,,)"))             { printf("("); print_tuple(n,3);  return; }
    if(!strcmp(n.n->symbol->name, "(,,,,)"))            { printf("("); print_tuple(n,4);  return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,)"))           { printf("("); print_tuple(n,5);  return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,)"))          { printf("("); print_tuple(n,6);  return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,)"))         { printf("("); print_tuple(n,7);  return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,)"))        { printf("("); print_tuple(n,8);  return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,)"))       { printf("("); print_tuple(n,9);  return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,)"))      { printf("("); print_tuple(n,10); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,,)"))     { printf("("); print_tuple(n,11); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,,,)"))    { printf("("); print_tuple(n,12); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,,,,)"))   { printf("("); print_tuple(n,13); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,,,,,)"))  { printf("("); print_tuple(n,14); return; }
    if(!strcmp(n.n->symbol->name, "(,,,,,,,,,,,,,,,)")) { printf("("); print_tuple(n,15); return; }
    if(child_at_i(n,1) == INT_CTR)
    {
        printf("%ld", child_at_i(n,0));
        return;
    }
    if(child_at_i(n,1) == CHAR_CTR)
    {
        printf("%c", (char)child_at_c(n,0));
        return;
    }
    if(child_at_i(n,1) == FLOAT_CTR)
    {
        printf("%lf", child_at_f(n,0));
        return;
    }
    printf("%s", n.n->symbol->name);
    if(n.n->symbol->arity)
    {
        printf("(");
        for(int i = n.n->symbol->arity-1; i > 0; i--)
        {
            if(i >= n.n->missing)
            {
                print_final(child_at_v(n,i));
                printf(", ");
            }
            else
            {
                printf("*, ");
            }
        }
        if(n.n->missing == 0)
            print_final(child_at_v(n,0));
        else
            printf("*");
        printf(")");
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

void ground_nf(union field expr)
{
    debug(LOW, "solving: ");
    debug_expr(LOW, expr);

    // If we're a function or choice, put ourselves in head normal form.
    if(TAG(expr) == CHOICE_TAG || 
       TAG(expr) == FUNCTION_TAG && expr.n->missing <= 0)
    {
        HNF(expr);
    }

    // if we're a variable, then we can't reduce to ground normal from
    if(TAG(expr) == FREE_TAG)
    {
        fail(expr);
        return;
    }

    debug(LOW, "HNF: ");
    debug_expr(LOW, expr);
    // If we're a primative value, then we're already in normal form.
    // int/float/char can't hold unevaluated expressions.
    if(child_at_i(expr,1) == INT_CTR ||
       child_at_i(expr,1) == CHAR_CTR ||
       child_at_i(expr,1) == FLOAT_CTR)
    {
        return;
    }
    
    // loop backwards because arguments are in reverse order.
    for(int i = expr.n->symbol->arity-1; i >= 0; i--)
    {
        union field e = child_at_v(expr,i);
        if(e.n != NULL)
        {
            ground_nf(e);
            if(TAG(e) == FAIL_TAG)
            {
                fail(expr);
            }
        }
    }
}

void nf(union field expr)
{
    debug(LOW, "solving: ");
    debug_expr(LOW, expr);
    // if we're a constructor, 
    // then we don't need to put ourselves in head normal form
    if(expr.n->missing <= 0)
    {
        HNF(expr);
    }
    debug(LOW, "HNF: ");
    debug_expr(LOW, expr);

    // If we're a primative value, then we're already in normal form.
    // int/float/char can't hold unevaluated expressions.
    if(child_at_i(expr,1) == INT_CTR ||
       child_at_i(expr,1) == CHAR_CTR ||
       child_at_i(expr,1) == FLOAT_CTR)
    {
        return;
    }
    
    for(int i = expr.n->symbol->arity-1; i >= 0; i--)
    {
        union field e = child_at_v(expr,i);
        nf(e);
        // we failed a child, so we fail.
        // put the current node on the stack, and fail it.
        if(TAG(e) == FAIL_TAG)
        {
            fail_nf(e,expr);
            // exit the loop.
            i = 0;
        }
    }
}

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

