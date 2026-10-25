#ifndef DEBUG_H
#define DEBUG_H

#include <stdio.h>

/* Leveled debug output.
 * Build with -DDEBUG=n (rice --debug=low|med|high) to turn it on.
 * Each macro prints only if DEBUG is at least `level`.
 * With DEBUG unset, all of these expand to nothing.
 */
#define LOW  1
#define MED  2
#define HIGH 3

#if DEBUG > 0
#define debug(level, args...)       \
    do {                            \
        if(DEBUG >= level)          \
        {                           \
            printf(args);           \
            fflush(stdout);         \
        }                           \
    } while(0)
#define debug_expr(level, node)     \
    do {                            \
        if(DEBUG >= level)          \
        {                           \
            print_expr(node);       \
            printf("\n");           \
            fflush(stdout);         \
        }                           \
    } while(0)
#define debug_trail(level)          \
    do {                            \
        if(DEBUG >= level)          \
        {                           \
            print_trail(trail);     \
        }                           \
    } while(0)
#define debug_trail_entry(level, entry) \
    do {                                \
        if(DEBUG >= level)              \
        {                               \
            print_trail_entry(entry);   \
        }                               \
    } while(0)
#else
#define debug(level, args...)           ((void)0)
#define debug_expr(level, node)         ((void)0)
#define debug_trail(level)              ((void)0)
#define debug_trail_entry(level, entry) ((void)0)
#endif

#endif // DEBUG_H
