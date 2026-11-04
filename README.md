Rice
====

Rice is an optimizing compiler for the functional logic language
[Curry](https://curry-lang.org). It compiles a Curry program to C, and from
there to a native executable.

Rice runs on 64-bit macOS and Linux. On Windows, use it under WSL2.

Installing
----------

### From a release (recommended)

You need `make` and a C compiler: clang 13 or later, or gcc 15 or later.
You don't need a Curry system or Haskell.

1. Download `rice-<version>.tar.xz` from the
   [releases page](https://github.com/libbys-up/rice/releases) and unpack it.
2. In the unpacked directory:

   ```bash
   make -j from-seed
   make install
   ```

`make from-seed` builds rice from the C it ships with (`seed/`), gets the
Curry front end, and compiles rice's standard library. `make install`
installs it into `~/.local` (`make install PREFIX=/some/dir` for elsewhere;
`make uninstall` removes it). Make sure `~/.local/bin` is on your `PATH`.

The Curry front end is a separate program, which rice runs to parse
Curry. `make` uses one you already have if it's the right version (from
KiCS2 or PAKCS, or `RICE_FRONTEND`), and otherwise downloads a prebuilt
one. If there isn't one for your platform, it builds it from source, which
needs [Haskell Stack](https://haskellstack.org) or cabal and takes a while.

### From a git clone (for working on rice)

Rice is written in Curry, and built with
[KiCS2](https://github.com/cau-placc/kics2) 3.5. You also need a C compiler
as above.

```bash
git clone --recurse-submodules https://github.com/libbys-up/rice.git
cd rice
make CYPM=/path/to/kics2/bin/cypm
make install
```

`make` gets the front end, builds rice with KiCS2's `cypm` (it stops if
`CYPM` belongs to another Curry system), and compiles the standard library.
Without `make install`, rice runs from `~/.cpm/bin/rice` and uses the
clone as its home, so keep the clone.

Using it
--------

```bash
rice Prog.curry                # builds ./Prog; main :: IO t runs once
rice --interactive Prog.curry  # main can have any type; prints every solution
```

`rice -v` says what's being compiled. `rice --help` lists the options;
`rice --help-dev` lists the ones for working on the compiler.

Modules are looked up in the current directory, then `CURRYPATH`, then
rice's `lib/`.

Rice uses the first C compiler it finds: `$RICE_CC` if you set it, then
`clang` (or `clang-NN`), then `$CC`, then `gcc`. `rice --gcc` uses gcc.

Limitations
-----------

- No encapsulated search (`Control.Search.*`, set functions) and no
  `catch`.
- `(=:=)` evaluates both sides to normal form before unifying, so a goal
  that relies on lazy unification with free variables can print its answers
  and then search forever.
- Only depth-first search, so a search space with an infinite branch may
  never return.
- In `--interactive`, an IO action run after a nondeterministic choice
  isn't run again correctly when the search backtracks over that choice.

`src/features-plan.md` has the plans for these.

Working on rice
---------------

See `src/developers-manual.tex`. The test bench is `tests/run.sh`
(`tests/README.md`); the coding standards are in `STYLE_GUIDE.md`.
