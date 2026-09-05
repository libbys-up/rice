# Rice runtime -- Phase 0 build (see STATUS.md's "runtime/ and Codegen"
# section for the full phase plan this fits into).
#
# Builds the standalone-compilable core of runtime/ -- node.h, macros.h,
# memory.h, debug.h, stack.{h,c}, runtime.{h,c} -- into a static library.
# -Wall -Wextra -Werror from day one: several of the bugs already found and
# fixed in this tree (wrong-arity self-recursion, a name mismatch, a
# bit-packing truncation, syntax errors) are things a compiler catches
# unconditionally the moment it's actually run over the file; there's no
# reason to let another one sit unbuilt long enough to be found by reading
# instead.
#
# external.c and Prelude_external.{h,c} are deliberately NOT part of this
# target: both #include a per-program-generated "Prelude.h" (codegen
# output -- e.g. Prelude__LB_RB_TAG, set_Prelude_True) that doesn't exist
# until Phase 1 lands, and external.c specifically needs a rewrite, not a
# patch, before it's worth compiling at all (see STATUS.md's Phase 2).
#
# bt_stack/mem (both `extern` in runtime.h) are deliberately *not* defined
# anywhere in this library -- they're meant to be defined once, by whatever
# provides main() (eventually Phase 1's generated driver; for now,
# test/runtime_smoke.c). A plain `make` only builds the library, so those
# stay unresolved externs in the .a until something links against it.

CC      ?= gcc
CFLAGS  ?= -std=c11 -Wall -Wextra -Werror -g
AR      ?= ar

# To build against the Boehm GC instead of the default calloc-based
# allocator (memory.h): make CFLAGS="-std=c11 -Wall -Wextra -Werror -g -DGC" \
#                             LDLIBS=-lgc

SRC := runtime.c stack.c
OBJ := $(SRC:.c=.o)
LIB := libriceruntime.a

TEST_SRC := ../test/runtime_smoke.c
TEST_BIN := runtime_smoke

.PHONY: all test clean

all: $(LIB)

$(LIB): $(OBJ)
	$(AR) rcs $@ $(OBJ)

%.o: %.c *.h
	$(CC) $(CFLAGS) -c -o $@ $<

test: $(TEST_BIN)
	./$(TEST_BIN)

$(TEST_BIN): $(TEST_SRC) $(LIB)
	$(CC) $(CFLAGS) -I. -o $@ $(TEST_SRC) $(LIB) $(LDLIBS)

clean:
	rm -f $(OBJ) $(LIB) $(TEST_BIN)
	rm -rf $(TEST_BIN).dSYM
