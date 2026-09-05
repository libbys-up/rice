#ifndef MEMORY_H
#define MEMORY_H

#include<stdlib.h>

#ifdef GC
#include<gc.h>
#define memory_init() GC_INIT()
#define alloc(size) GC_MALLOC(size)
#else
// alloc(size) has to remain a single *expression* (it's always used as one,
// e.g. `(Node*)alloc(sizeof(Node))`), so this can't be a `do{...}while(0)`
// statement-block -- that idiom is for void macros, and would make alloc
// unusable in exactly the contexts it's used in. The comma operator gets
// both effects (bump mem, then yield calloc's result) as one parenthesized
// expression, safe to substitute anywhere an expression is expected
// (a bare `calloc(1,size); mem++` is two statements, and silently breaks
// e.g. `if(cond) x = alloc(n);` or use as a function argument).
#define alloc(size) (mem++, calloc(1,size))
#define memory_init() mem = 0
#endif

#endif
