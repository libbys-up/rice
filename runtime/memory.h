#ifndef MEMORY_H
#define MEMORY_H

#include<stdlib.h>

#ifdef GC
#include<gc.h>
#define memory_init() GC_INIT()
#define alloc(size) GC_MALLOC(size)
#else
// We use (mem++, calloc(1,size)) to get two effects in the same expression.
// It would probably be better to make this a statement (or a function call).
//
// There are still examples where this breaks, so it should probably be updated.
// e.g. `if(cond) x = alloc(n);` or use as a function argument).
#define alloc(size) (mem++, calloc(1,size))
#define memory_init() mem = 0
#endif

#endif
