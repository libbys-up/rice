# Rice runtime Phase 0 build (see STATUS.md's "runtime/ and Codegen"
# section for the full phase plan this fits into).
#
# Builds the standalone-compilable core of runtime/ -- node.h, macros.h,
# memory.h, debug.h, stack.{h,c}, runtime.{h,c} -- into a static library.
#
# prelude.c is deliberately NOT part of this target: it #includes a
# per-program-generated "Prelude.h" (codegen output -- e.g.
# Prelude__LB_RB_TAG, set_Prelude__True) that doesn't exist until a real
# module is compiled, so it can't be built standalone against just this
# library.
# See Rice.Main's buildExecutable, which links it directly
# alongside a specific program's generated .c files instead.
#
# bt_stack/mem (both `extern` in runtime.h) are deliberately *not* defined
# anywhere in this library.  They're meant to be defined once by whatever
# provides main()

CC      ?= gcc
CFLAGS  ?= -std=c11 -Wall -Wextra -Werror -g
AR      ?= ar

# To build against the Boehm GC instead of the default calloc-based
# allocator (memory.h): make CFLAGS="-std=c11 -Wall -Wextra -Werror -g -DGC" \
#                             LDLIBS=-lgc
# This is experimental, not verified to work.
# I'll probably replace Boehm with a custom GC later.

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
