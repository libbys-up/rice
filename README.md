Rice
====

Rice is an optimizing compiler for the functional logic language
[Curry](https://curry-lang.org). It compiles a Curry program to C, and from
there to a native executable.

Installing
----------

You need:

- a Curry system with `cypm`, to build rice itself. Rice is tested with
  [KiCS2](https://github.com/cau-placc/kics2) 3.5;
- [Haskell Stack](https://haskellstack.org) or cabal, to build the Curry
  front end;
- clang 13 or later (or gcc 15 or later, with `rice --gcc`).

Then, in a clone of this repository:

```bash
git submodule update --init
make CYPM=/path/to/kics2/bin/cypm
```

This builds the Curry front end from the pinned `frontend/` submodule into
`bin/`, installs `rice` into `~/.cpm/bin` with `cypm install`, and compiles
rice's standard library (`lib/`). Keep the clone: rice finds its library and
runtime there. Set `RICEHOME` to use a different copy.

`cypm install` on its own also works. Rice then uses the front end of the
Curry system that built it, so the front end version isn't pinned, and the
first program you compile also compiles the Prelude, which takes a minute.

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

Limitations
-----------

- No encapsulated search (`Control.Search.*`, set functions).
- `(=:=)` evaluates both sides to normal form before unifying, so a goal
  that relies on lazy unification with free variables can print its answers
  and then search forever.
- Only Prelude's external functions are implemented. Library modules with
  other externals (`Data.IORef`, `System.IO.Unsafe`, ...) don't link.
- A constructor can have at most 49 fields.
- 64-bit platforms only. Tested on macOS (arm64).

Working on rice
---------------

See `src/developers-manual.tex`. The test bench is `tests/run.sh`
(`tests/README.md`).
