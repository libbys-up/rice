// The externals of System.IO.
//
// Handle is an external data type, so it has no constructor in the
// generated code. A handle is a node with handle_symbol and two raw
// fields: the FILE*, and whether it can be read (bit 0) and written
// (bit 1). Its tag is the first constructor tag; Handle has no cases.

#include <poll.h>
#include <stdlib.h>
#include <unistd.h>
#include "ext.h"
#include "System/IO.h"

#define HANDLE_READ  1
#define HANDLE_WRITE 2

static const unsigned char handle_reps[] = { R_INT, R_INT };
static Symbol handle_symbol =
    { .tag = FREE_TAG + 1, .arity = 2, .name = "Handle",
      .reps = handle_reps, .hnf = &CTR_hnf };

field ext_mk_handle(FILE* f, bool readable, bool writable)
{
    field h;
    h.n = (Node*)alloc(sizeof(Node));
    #if OPT_EPOCH_TRAIL
    h.n->epoch = current_epoch;
    #endif
    h.n->symbol = &handle_symbol;
    h.n->missing = 0;
    h.n->children[3].a = NULL;
    child_at(h, 0).i = (long)f;
    child_at(h, 1).i = (readable ? HANDLE_READ : 0) | (writable ? HANDLE_WRITE : 0);
    return h;
}

FILE* ext_handle(field h)
{
    return (FILE*)child_at_i(ext_hnf(h), 0);
}

static long handle_flags(field h)
{
    return child_at_i(ext_hnf(h), 1);
}

EXT(System_DOIO__handle_USeq)
{
    GC_ROOT(root);
    FILE* a = ext_handle(child_at(root, 0));
    FILE* b = ext_handle(child_at(root, 1));
    GC_UNROOT(1);
    ext_return_bool(root, a == b);
}

EXT(System_DOIO__stdin)
{
    ext_return(root, ext_mk_handle(stdin, true, false));
}

EXT(System_DOIO__stdout)
{
    ext_return(root, ext_mk_handle(stdout, false, true));
}

EXT(System_DOIO__stderr)
{
    ext_return(root, ext_mk_handle(stderr, false, true));
}

EXT(System_DOIO__prim_USopenFile)
{
    GC_ROOT(root);
    char* path = ext_string(child_at(root, 0));
    unsigned char mode = ext_tag(child_at(root, 1));
    GC_UNROOT(1);
    const char* fmode = mode == System_DOIO__ReadMode_TAG  ? "r"
                      : mode == System_DOIO__WriteMode_TAG ? "w"
                      : "a";
    FILE* f = fopen(path, fmode);
    if(f == NULL)
    {
        ext_io_error("openFile", path, root);
    }
    free(path);
    bool reading = mode == System_DOIO__ReadMode_TAG;
    ext_return(root, ext_mk_handle(f, reading, !reading));
}

EXT(System_DOIO__prim_UShClose)
{
    GC_ROOT(root);
    FILE* f = ext_handle(child_at(root, 0));
    GC_UNROOT(1);
    if(f != stdin && f != stdout && f != stderr)
    {
        fclose(f);
    }
    ext_return_unit(root);
}

EXT(System_DOIO__prim_UShFlush)
{
    GC_ROOT(root);
    FILE* f = ext_handle(child_at(root, 0));
    GC_UNROOT(1);
    fflush(f);
    ext_return_unit(root);
}

EXT(System_DOIO__prim_UShIsEOF)
{
    GC_ROOT(root);
    FILE* f = ext_handle(child_at(root, 0));
    GC_UNROOT(1);
    int c = getc(f);
    if(c != EOF)
    {
        ungetc(c, f);
    }
    ext_return_bool(root, c == EOF);
}

EXT(System_DOIO__prim_UShSeek)
{
    GC_ROOT(root);
    FILE* f = ext_handle(child_at(root, 0));
    unsigned char mode = ext_tag(child_at(root, 1));
    long offset = ext_int(child_at(root, 2));
    GC_UNROOT(1);
    int whence = mode == System_DOIO__AbsoluteSeek_TAG ? SEEK_SET
               : mode == System_DOIO__RelativeSeek_TAG ? SEEK_CUR
               : SEEK_END;
    if(fseek(f, offset, whence) != 0)
    {
        ext_io_error("hSeek", "handle", root);
    }
    ext_return_unit(root);
}

// Whether input is waiting on f within `timeout` milliseconds (negative:
// wait as long as it takes). This asks poll about the file descriptor, so
// it misses characters already read into f's buffer; C has no portable
// way to look there.
static bool input_ready(FILE* f, int timeout)
{
    struct pollfd p = { .fd = fileno(f), .events = POLLIN };
    return poll(&p, 1, timeout) > 0;
}

EXT(System_DOIO__prim_UShWaitForInput)
{
    GC_ROOT(root);
    FILE* f = ext_handle(child_at(root, 0));
    long timeout = ext_int(child_at(root, 1));
    GC_UNROOT(1);
    ext_return_bool(root, input_ready(f, (int)timeout));
}

// The index of the first handle with input waiting, or -1 if none has any
// within the timeout.
EXT(System_DOIO__prim_UShWaitForInputs)
{
    GC_ROOT(root);
    long timeout = ext_int(child_at(root, 1));
    // Collect the handles' file descriptors.
    size_t n = 0, cap = 4;
    struct pollfd* ps = malloc(cap * sizeof(struct pollfd));
    field list = child_at(root, 0);
    GC_ROOT(list);
    list = ext_hnf(list);
    while(list.n->symbol->tag == Prelude___CO_TAG)
    {
        FILE* f = ext_handle(child_at(list, 0));
        if(n == cap)
        {
            cap *= 2;
            ps = realloc(ps, cap * sizeof(struct pollfd));
        }
        ps[n++] = (struct pollfd){ .fd = fileno(f), .events = POLLIN };
        list = ext_hnf(child_at(list, 1));
    }
    GC_UNROOT(2);
    long ready = -1;
    if(poll(ps, (nfds_t)n, (int)timeout) > 0)
    {
        for(size_t i = 0; i < n; i++)
        {
            if(ps[i].revents & POLLIN)
            {
                ready = (long)i;
                break;
            }
        }
    }
    free(ps);
    ext_return_int(root, ready);
}

EXT(System_DOIO__prim_UShGetChar)
{
    GC_ROOT(root);
    FILE* f = ext_handle(child_at(root, 0));
    GC_UNROOT(1);
    int c = getc(f);
    if(c == EOF)
    {
        error("hGetChar: end of file", root);
    }
    ext_return(root, make_Prelude__Char((field)(unsigned long)(unsigned char)c, 0));
}

EXT(System_DOIO__prim_UShPutChar)
{
    GC_ROOT(root);
    FILE* f = ext_handle(child_at(root, 0));
    char c = ext_char(child_at(root, 1));
    GC_UNROOT(1);
    putc(c, f);
    ext_return_unit(root);
}

EXT(System_DOIO__prim_UShIsReadable)
{
    GC_ROOT(root);
    long flags = handle_flags(child_at(root, 0));
    GC_UNROOT(1);
    ext_return_bool(root, flags & HANDLE_READ);
}

EXT(System_DOIO__prim_UShIsWritable)
{
    GC_ROOT(root);
    long flags = handle_flags(child_at(root, 0));
    GC_UNROOT(1);
    ext_return_bool(root, flags & HANDLE_WRITE);
}

EXT(System_DOIO__prim_UShIsTerminalDevice)
{
    GC_ROOT(root);
    FILE* f = ext_handle(child_at(root, 0));
    GC_UNROOT(1);
    ext_return_bool(root, isatty(fileno(f)));
}
