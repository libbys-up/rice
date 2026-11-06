# Builds the runtime on its own, for tests/runtime_smoke.c (`make test`).
# rice doesn't use this: Rice.Main compiles the runtime itself, with -O2.
# Running it overwrites the runtime/*.o files rice links with unoptimized
# -g builds; if that happens, rm runtime/*.o runtime/*.o.flags.
#
# Builds the standalone-compilable core of runtime/ -- node.h, macros.h,
# memory.h, debug.h, trail.{h,c}, machine.{h,c}, heap.c, gc.{h,c},
# runtime.{h,c} -- into a static library.
#
# ext/Prelude.c is deliberately NOT part of this target: it #includes a
# per-program-generated "Prelude.h" (codegen output -- e.g.
# Prelude__LB_RB_TAG, set_Prelude__True) that doesn't exist until a real
# module is compiled, so it can't be built standalone against just this
# library.
# See Rice.Main's buildExecutable, which links it directly
# alongside a specific program's generated .c files instead.
#
# trail/mem (both `extern` in runtime.h) are deliberately *not* defined
# anywhere in this library.  They're meant to be defined once by whatever
# provides main()

CC      ?= gcc
CFLAGS  ?= -std=c11 -D_DEFAULT_SOURCE -Wall -Wextra -Werror -g
AR      ?= ar

SRC := runtime.c trail.c machine.c heap.c gc.c
OBJ := $(SRC:.c=.o)
LIB := libriceruntime.a

TEST_SRC := ../tests/runtime_smoke.c
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
