# Builds and installs rice.
#
#   make            the front end, rice, and the precompiled Prelude
#   make frontend   just bin/curry-frontend, from the frontend/ submodule
#   make rice       just the rice executable (cypm install)
#   make prelude    just compile lib/'s Prelude, so the first program
#                   doesn't have to
#   make clean      remove what this Makefile built, and rice's caches
#
# Needs: Haskell Stack (or cabal) for the front end, a Curry system with
# cypm for rice itself, and clang (or gcc 15 or later).
#
# CYPM is the cypm that builds rice. KiCS2's is the one rice is tested with:
#   make CYPM=~/opt/kics2/bin/cypm

CYPM  ?= cypm
# where cypm installs rice
RICE  ?= $(HOME)/.cpm/bin/rice
STACK ?= stack
CABAL ?= cabal

BINDIR   := $(CURDIR)/bin
FRONTEND := $(BINDIR)/curry-frontend

.PHONY: all install frontend rice prelude clean

all: frontend rice prelude

install: all

frontend: $(FRONTEND)

# The submodule pins the front end version rice is tested with.
$(FRONTEND): frontend/curry-frontend.cabal
	mkdir -p $(BINDIR)
	if command -v $(STACK) >/dev/null 2>&1; then \
	  cd frontend && $(STACK) install --local-bin-path $(BINDIR); \
	elif command -v $(CABAL) >/dev/null 2>&1; then \
	  cd frontend && $(CABAL) install exe:curry-frontend \
	    --installdir=$(BINDIR) --install-method=copy --overwrite-policy=always; \
	else \
	  echo "Building the front end needs Haskell Stack or cabal." >&2; exit 1; \
	fi
	touch $(FRONTEND)

frontend/curry-frontend.cabal:
	git submodule update --init frontend

rice:
	$(CYPM) install

# Compiling Prelude takes a while, so do it once here. rice keeps the
# result in lib/.curry/.
prelude:
	tmp=$$(mktemp -d) && \
	printf 'main :: IO ()\nmain = return ()\n' > $$tmp/Setup.curry && \
	( cd $$tmp && RICEHOME=$(CURDIR) $(RICE) Setup.curry ) && \
	rm -rf $$tmp

clean:
	rm -rf $(BINDIR) lib/.curry replace/.curry runtime/obj-*
