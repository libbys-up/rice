# Builds and installs rice.
#
# From a release tarball (rice-<version>.tar.xz), which has the C rice
# generates for itself in seed/, you need only make and a C compiler
# (clang 13 or later, or gcc 15 or later):
#
#   make -j from-seed   the front end, bin/rice from seed/, and the library
#   make install        install into PREFIX (default ~/.local)
#
# From a git clone, rice is built with KiCS2:
#
#   make CYPM=/path/to/kics2/bin/cypm
#                       the front end, rice (cypm install), and the library
#   make install        install into PREFIX (default ~/.local)
#
# The pieces:
#   make frontend       bin/curry-frontend: reuse one at the right version,
#                       or download it, or build it (tools/get-frontend.sh)
#   make frontend-from-source
#                       build bin/curry-frontend from frontend/ (Haskell
#                       Stack or cabal)
#   make rice           rice, with cypm (into ~/.cpm/bin)
#   make stdlib         compile lib/, so programs don't have to
#   make seed           write a release tarball (tools/make-seed.sh)
#   make uninstall      remove what make install installed
#   make clean          remove what this Makefile built, and rice's caches

CYPM   ?= cypm
# where cypm installs rice
RICE   ?= $(HOME)/.cpm/bin/rice
PREFIX ?= $(HOME)/.local

BINDIR   := $(CURDIR)/bin
FRONTEND := $(BINDIR)/curry-frontend
RICEDIR   = $(PREFIX)/lib/rice

.PHONY: all frontend frontend-from-source rice stdlib prelude from-seed \
        seed-rice seed install uninstall clean

all: frontend rice stdlib

frontend:
	tools/get-frontend.sh

frontend-from-source:
	tools/get-frontend.sh --source

# Rice is built with KiCS2. A PAKCS-built rice compiles, but fails on every
# program, so stop if $(CYPM) belongs to another Curry system.
rice:
	@tools/check-cypm.sh $(CYPM)
	$(CYPM) install

# Compile every library module now, so the first program that uses one
# doesn't have to. rice keeps the results in lib/.curry/.
stdlib:
	tools/precompile-lib.sh $(RICE) $(CURDIR)

prelude: stdlib

# --- Building from the seed -------------------------------------------

# The same C compiler rice would choose (tools/find-cc.sh): clang if
# there is one, not make's default cc, which is often an older gcc.
SEED_CC     := $(shell tools/find-cc.sh 2>/dev/null)
SEED_CFLAGS := -std=c11 -O2 -Iruntime -Iseed/gen
SEED_RUNTIME := runtime.c trail.c machine.c heap.c gc.c ext.c
SEED_C   = $(shell find seed/gen -name '*.c' -not -name '._*' 2>/dev/null) seed/rice-main.c \
           $(addprefix runtime/,$(SEED_RUNTIME)) \
           $(addprefix runtime/ext/,$(addsuffix .c,$(shell cat seed/ext.txt 2>/dev/null)))
SEED_OBJ = $(patsubst %.c,seed/obj/%.o,$(SEED_C))

from-seed:
	@test -f seed/ext.txt || { echo "No seed/: from-seed needs a release tarball (make seed)." >&2; exit 1; }
	@test -n "$(SEED_CC)" || tools/find-cc.sh
	$(MAKE) frontend
	$(MAKE) seed-rice
	$(MAKE) stdlib RICE=$(BINDIR)/rice

seed-rice: $(BINDIR)/rice

$(BINDIR)/rice: $(SEED_OBJ)
	mkdir -p $(BINDIR)
	$(SEED_CC) $(SEED_OBJ) -lm -o $@

# rice-main.c records where rice is installed: here.
seed/obj/seed/rice-main.o: seed/rice-main.c
	@mkdir -p $(dir $@)
	$(SEED_CC) $(SEED_CFLAGS) -DRICE_INSTALL_DIR='"$(CURDIR)"' -c $< -o $@

seed/obj/%.o: %.c
	@mkdir -p $(dir $@)
	$(SEED_CC) $(SEED_CFLAGS) -c $< -o $@

seed:
	tools/make-seed.sh $(RICE)

# --- Installing -------------------------------------------------------

# Everything rice needs goes in $(PREFIX)/lib/rice. $(PREFIX)/bin/rice is a
# small script that runs it with RICEHOME set there (unless you've set
# RICEHOME yourself), which works for a rice built either way. The library
# is compiled at install time, so rice doesn't write into the installation
# afterwards, except for objects built with other C flags (--cflags,
# --debug, --gcc).
install:
	@if [ -x $(BINDIR)/rice ]; then built=$(BINDIR)/rice; \
	 elif [ -x $(RICE) ]; then built=$(RICE); \
	 else echo "Nothing to install: run make (or make from-seed) first." >&2; exit 1; fi; \
	 test -x $(FRONTEND) || { echo "No front end: run make frontend first." >&2; exit 1; }; \
	 echo "Installing $$built into $(RICEDIR)"; \
	 rm -rf $(RICEDIR) && mkdir -p $(RICEDIR)/bin $(PREFIX)/bin && \
	 tar -cf - --exclude .curry --exclude 'obj-*' --exclude '*.o' --exclude '*.a' \
	     --exclude runtime_smoke --exclude 'runtime_smoke.dSYM' lib replace runtime \
	   | ( cd $(RICEDIR) && tar -xf - ) && \
	 cp $$built $(RICEDIR)/bin/rice && \
	 cp -L $(FRONTEND) $(RICEDIR)/bin/curry-frontend && \
	 printf '#!/bin/sh\n: "$${RICEHOME:=%s}"\nexport RICEHOME\nexec "%s/bin/rice" "$$@"\n' \
	     "$(RICEDIR)" "$(RICEDIR)" > $(PREFIX)/bin/rice && \
	 chmod +x $(PREFIX)/bin/rice && \
	 tools/precompile-lib.sh $(PREFIX)/bin/rice $(RICEDIR) && \
	 echo "Installed. Make sure $(PREFIX)/bin is on your PATH."

uninstall:
	rm -rf $(RICEDIR) $(PREFIX)/bin/rice

clean:
	rm -rf $(BINDIR) lib/.curry replace/.curry runtime/obj-* seed/obj
