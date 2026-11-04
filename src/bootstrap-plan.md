Plan: bootstrapping Rice (compiling Rice with Rice)
===================================================

Written 2026-10-04. A starting plan, not a finished design. The numbers
below come from a survey of the source tree and should be checked again
before each phase starts.

Goal, in two stages:

1. **Self-hosting.** A `rice` built by kics2 (`rice0`) compiles Rice's own
   source into a working `rice1`. `rice1` compiles Rice again into `rice2`,
   and `rice1`/`rice2` generate identical C.
2. **Independence from kics2.** A fresh machine can build Rice with only a
   C compiler and the Curry frontend binary. No kics2 or PAKCS install is
   needed, and that includes `cypm`.

The constraint throughout: **Rice must keep building and running under
kics2.** The kics2-built path stays a supported, tested configuration. It
does not get dropped once self-hosting works.

------------------------------------------------------------------------------

Status, 2026-11-03
------------------

Both goals are met.

- **B.4, reading caches.** The `.rtfcy`/`.rfcy` caches are in rw-data's
  compact format, the module graph reads only each `.tfcy`'s header, and
  under KiCS2 the `.tfcy` is parsed with `ReadShowTerm`. rice1 compiles
  hello world in 0.6 s and 194 MB (was 43 s and 5.7 GB); cold, compiling
  Prelude too, 45 s and 2.8 GB. rice0 cold: 13.7 s and 713 MB.
- **The fixpoint.** `tests/bootstrap.sh --fixpoint` passes: rice0, rice1
  and rice2 generate identical C for rice (165 files). rice1 builds rice2
  in under 5 minutes (was 31).
- **B.3, `Int` width.** Audited: the only arithmetic on big values in
  rice is the object-directory hash, `(h * 33 + ord c) mod 2^32`, which
  stays under 2^38. (A user program with an integer literal wider than 64
  bits is wrong under either: rice0 writes it into C as is, rice1
  overflows reading it.)
- **Phase D, the seed.** Decided 2026-11-03: the seed goes in release
  tarballs, not the repo. `make seed` (`tools/make-seed.sh`) stages HEAD,
  the front end's source and the packages' sources, has rice compile
  Rice.Main there, and writes `rice-<version>.tar.xz` (3 MB) with the
  generated C in `seed/`. `make -j from-seed` builds the front end,
  `bin/rice` from `seed/` with only `cc` (53 s on 8 cores), and Prelude.
  Checked: with no Curry system on `PATH`, the seed builds a rice that
  runs the tests, and that rice compiles Rice.Main from the tarball's
  source into C identical to the seed (164 files; `rice-main.c` records
  the install directory). A rice-built rice finds its home from
  `rice_install_dir`, which the seed build sets with `-DRICE_INSTALL_DIR`.

Left:
- The front end still needs Haskell (Stack or cabal) to build, as
  planned. A release could also ship front end binaries.
- A Linux run of `make from-seed`, and CI that runs both build paths.
- rice1 parses `.tfcy` with derived `read` (9 s for Prelude). A reader
  written for rice, building terms from the file's bytes with no
  `String`, would fix that and replace rw-data (features-plan.md).
- An uncaught `error` in a rice-built program prints its message, then the
  raw `prim_error(...)` term.

------------------------------------------------------------------------------

Status, 2026-10-29
------------------

Done since this plan was written:

- **B.1 GC and B.2 stack depth.** The precise copying collector and the
  evaluation machine replaced both. Boehm is gone.
- **Compiler identity.** Rice is "rice": its own `lib/` (KiCS2's, with
  `__RICE__`), its own front end call (`Rice.Frontend`), and
  `.curry/rice-1.0.0/`. The front end is pinned (`frontend/` submodule,
  `make frontend`).
- **Rice's closure compiles to objects.** `rice Rice.Main` (from `src/`,
  with `CURRYPATH` set to `packageLoadPath` from `Rice.PackageConfig`)
  compiles all 77 modules to C and object files in about 6 minutes. Getting
  there fixed four bugs, each now a regression test: newtypes
  (`-Odesugar-newtypes`), headers of modules with the same last name
  component, names with `\` or `"` in C strings and comments, and the C
  driver `main.c` overwriting a module `Main`'s `Main.c` on a
  case-insensitive file system.

- **Phase A.1–A.2, externals.** `runtime/ext/M.c` holds module `M`'s
  externals (`ext.h` has the helpers), and `Rice.Main` links the ones the
  program's modules need, or names what's missing. Done: System.IO
  (handles), System.Directory, System.Environment, System.Process,
  System.CPUTime, Data.Time, Curry.Compiler.Distribution. Stubs:
  System.IOExts's commands, ReadShowTerm, `catch`; rice doesn't call them.
- **rice1 exists.** `rice Rice.Main` links (about 6 minutes, 61 MB), and
  that rice1 compiles and links a hello world that runs. Against rice0
  (KiCS2-built), with Prelude already cached: 43 s and 5.7 GB peak, against
  12 s and 4.5 GB. 35 s of that is reading the cached Prelude (`.rtfcy`,
  `.rfcy`) with derived `Read` (B.4).

- **Phase C, the triple test, passes** (2026-10-30, `tests/bootstrap.sh`):
  rice0 builds rice1 and rice1 builds rice2, each from scratch in a fresh
  copy of the tree, and all 157 generated `.c`/`.h` files are identical.
  rice1 building rice2 took 31 minutes and 4.6 GB in an earlier run.
  Getting there found three runtime bugs, fixed in `649adf4`: `read`
  didn't know Haskell's escapes (`'\DEL'`), a failed IO action was
  silently skipped, and `show` on Float was C's `%f`, so rice1 compiled
  float constants to six decimals.

Next:
- B.4: rice1 spends most of a small compile reading cached `.rtfcy` and
  `.rfcy` files with derived `Read` (35 of 43 s on hello world). A
  hand-written reader would help rice0 too.
- `tests/bootstrap.sh --fixpoint` (rice2 builds rice3) hasn't been run.
- B.3: the `Int` width audit.
- Phase D: the seed C, and building without KiCS2.

------------------------------------------------------------------------------

Where we are (2026-10-04)
-------------------------

What Rice compiles today is the Prelude plus user modules that contain no
`external` declarations. `Rice.Main` links exactly `runtime.c`, `stack.c`,
`prelude.c`, and the generated files (`Main.curry:247`). `ToC` emits nothing
for `IExternal` (`ToC.curry:179`). So no non-Prelude module with externals
can link yet.

Rice's transitive import closure (`Rice.Main` plus every library it pulls
in) is **76 modules**. Its own source is about 5.5k lines. Every library
module that needs an external outside the Prelude:

| Module | Externals | Notes |
|---|---|---|
| `Prelude` | ~60 distinct | mostly done in `prelude.c`. `catch` is still stubbed |
| `System.IO` | 16 | handles: `openFile`/`hClose`/`hGetChar`/`hPutChar`/`hFlush`/`hIsEOF`/... |
| `System.Directory` | 12 | `doesFileExist`, `getModificationTime`, `createDirectory`, ... |
| `System.Environment` | 7 | `getArgs`, `getEnviron`, `getProgName`, ... |
| `System.Process` | 4 | `system`, `exitWith`, `getPID`, `sleep` |
| `System.IOExts` | 3 | `execCmd`/`evalCmd`/`connectToCmd` (pipes to a subprocess) |
| `Data.Time` | 4 | `getClockTime` + calendar conversions (needed for mtime comparisons) |
| `System.CPUTime` | 2 | `getCPUTime`, `getElapsedTime` (`--time`) |
| `ReadShowTerm` | 2 | `showTerm`/`readsUnqualifiedTerm` |
| `Curry.Compiler.Distribution` | 9 | compiler identity. See "Compiler identity" below |

Total: about 60 non-Prelude externals. All of them are thin libc/POSIX
wrappers. None of them needs search or nondeterminism support.

Things the closure *doesn't* need, as far as I can tell: `IORef`, set
functions/`findall`, `unsafePerformIO`, or narrowing on literal case
scrutinees. `catch` appears only in `System.IOExts` and
`FlatCurry.FilesRW`, and the second one may not even be in the closure.
Re-check when the closure changes.

------------------------------------------------------------------------------

Phase A: compile arbitrary library modules
------------------------------------------

The prerequisite for everything else. It's useful on its own too, since
real user programs need `System.IO`, `Data.Map`, and so on.

1. **An externals mechanism for non-Prelude modules.** Proposal: one
   hand-written C file per module with externals, found by convention.
   For example `runtime/lib/System_Directory.c`, named after the module's
   C mangling so it lines up with the `.h` that `ToH` already generates.
   The driver links it only when that module is in the build graph. A
   missing file is a link-time error that names the module, not a silent
   stub. `prelude.c` becomes the first instance of the convention, not a
   special case.
2. **Write the ~60 externals** in the table above. Most are small.
   `System.IO` handles need a new node kind (or a boxed `FILE*` in a
   primitive field) and an equality function (`handle_eq`).
3. **`catch` / `ioError` for real.** At minimum, catch an `IOError` raised
   by an external. `prim_ioError` already exists, but nothing unwinds to a
   handler yet. The C stack is the hard part, because `catch` needs a
   `setjmp` at the catch point, or IO errors have to be returned as values
   in the runtime.
4. **A closure smoke test.** Add a test that compiles every module in
   Rice's closure (each with a trivial `main` that touches it) and a few
   programs that use each external. This turns "what breaks" into a list
   instead of a surprise found in the middle of bootstrapping.

Exit criterion: `rice` can compile and link a program that imports
`Rice.Main`'s full closure, even if running it isn't fast yet.

------------------------------------------------------------------------------

Phase B: run at compiler scale
------------------------------

Rice's test programs are small. Rice itself reads a ~2MB `Prelude.tfcy`
through a derived `Read` instance. That parse alone takes ~4s under kics2
(`Build/Deps.curry:39`). The real workload is about 1300 Prelude functions
through every pass.

1. **GC.** The default allocator (`memory.h`) is calloc that never frees.
   This won't survive parsing the Prelude. Short term: make Boehm (`-DGC`,
   `-lgc`) a supported mode and turn it on for large builds. Long term: the
   custom GC already noted in the `Makefile`. Boehm is the fastest way to
   unblock bootstrapping. Don't make the custom GC a prerequisite.
2. **Stack depth.** Derived `Read`, `Data.Map`, and pretty-printing recurse
   deeply on non-tail calls. Check how deep the generated code can go
   before overflowing the C stack. Options: run evaluation on a large
   `mmap`ed stack, or raise the limit with `setrlimit` and re-exec at
   startup.
3. **`Int` width.** kics2's `Int` is arbitrary precision. Rice's is a C
   `long` (`node.h:13`). Rice's own code probably never exceeds 64 bits.
   Clock times and file sizes fit. But this needs an audit, not an
   assumption, especially around `Data.Time` and hashing.
4. **Performance of `read`.** If the derived-`Read` parse is too slow under
   Rice, the fix is in the reader, not the runtime. Write a hand-written
   (or `ReadShowTerm`-style) `TProg` reader. It helps the kics2 build too.
5. **Compiler identity.** See the section below. It has to be decided
   before Phase C, because it changes which files the frontend reads and
   writes.

Exit criterion: a Rice-compiled program that does what `Rice.Main` does on
the Prelude (read `.tfcy`, optimize, ANF, ICurry, print C), in comparable
time and bounded memory.

------------------------------------------------------------------------------

Phase C: self-hosting (the triple test)
---------------------------------------

1. `rice0` = Rice built by kics2 (today's binary).
2. `rice0` compiles Rice → `rice1`.
3. Run the whole `tests/run.sh` suite with `rice1` as the compiler. The
   generated C must be **byte-identical** to `rice0`'s for every test.
   This is a stronger check than "the tests pass", and it costs nothing.
4. `rice1` compiles Rice → `rice2`. `rice1`'s and `rice2`'s generated C
   must be identical (fixpoint).
5. Make the triple test a script (`tests/bootstrap.sh`) and run it before
   any commit that touches codegen, the runtime, or the optimizer, the
   same as `run.sh`.

Differences between `rice0` and `rice1` are the interesting bugs here.
Each one is a place where Rice's semantics differ from kics2's on real
code. Rice is also the largest program the runtime will have run so far,
so expect Phase C to find runtime bugs, not just missing features.

------------------------------------------------------------------------------

Phase D: drop the kics2 dependency
----------------------------------

What kics2 currently provides, and what replaces each piece:

| Provided by kics2 today | Replacement |
|---|---|
| The Rice binary itself (kics2 → GHC) | `rice1` (Phase C) |
| **The frontend** (`kics2-frontend`, which is `curry-frontend`, a Haskell program) | Build `curry-frontend` from source (it's a standalone package), or ship a prebuilt binary. Probably stays a Haskell dependency for a long time. Rewriting the frontend in Curry is a separate, much bigger project |
| Base libraries (`~/opt/kics2/lib`) | The `base` package sources, unchanged. Only the externals differ, and those are Rice's own C files from Phase A |
| `cypm` and package resolution | Short term: a Rice build script that sets `CURRYPATH` to vendored package sources (the dependency list in `package.json` is short and pinned). Long term: compile `cypm` with Rice |
| A seed for fresh machines | **Ship generated C for Rice** (the output of `rice1` compiling Rice) in the repo or release tarball, the way many self-hosted compilers ship a bootstrap seed. A fresh build is then `cc` + `curry-frontend` → `rice`, then `rice` rebuilds itself from source |

After Phase D, kics2 is an *optional* way to build Rice, kept working by
running both build paths in CI. That's the compatibility goal.

------------------------------------------------------------------------------

Compiler identity (decide before Phase C)
-----------------------------------------

`Curry.Compiler.Distribution` answers `curryCompiler`, `installDir`, and
the version numbers. Through `currypath`/`frontend-exec`, that controls:

- the frontend's location: `installDir/bin/<curryCompiler>-frontend`
  (`FrontendExec.curry:93`)
- the CPP define: `__<CURRYCOMPILER>__`, used by `Prelude`, `IORef`,
  `IOExts`, `ReadShowTerm`, `SetFunctions`, `Random`, ...
- the cache directory: `.curry/<curryCompiler>-<version>/`
- the system library path (`sysLibPath`)

Options:

- **Say "kics2".** Least work, since every `#ifdef __KICS2__` branch
  already exists. But it's a lie. `rice1` would read and write kics2's
  cache namespace, which is the same bug `Build/Cache.curry` already works
  around. And kics2-branch code assumes kics2 primitives exist.
- **Say "rice" (recommended).** `.curry/rice-1.0.0/` becomes the natural
  cache location, so the hand-rolled path in `Build.Cache` goes away. Rice
  needs its own `__RICE__` branches. Most libraries fall through to a
  default branch, and `replace/` already overrides the Prelude's. A
  `rice-frontend` symlink or wrapper under `$RICEHOME/bin` points at
  `curry-frontend`.

The `rice0` build (running under kics2) keeps reporting "kics2" for itself,
because that's what it is. So `Rice.Build.Cache` has to compute Rice's
*target* identity separately from the identity of the compiler it's
running on, which it already partly does.

------------------------------------------------------------------------------

Open questions
--------------

- The C file naming and location convention for per-module externals
  (Phase A.1). This affects user programs too, not just Rice.
- Ship Boehm as a hard dependency for now, or vendor it?
- Is the seed C checked into the repo (simple, but large diffs) or only in
  release tarballs?
- How much does `rice1`'s speed matter at first? A slow-but-correct
  `rice1` is enough to *validate* self-hosting. Day-to-day development can
  stay on `rice0` until `rice1` is competitive.

Suggested first step: the closure smoke test from Phase A.4, run against
today's `rice`. That gives a concrete list of what breaks before anything
is designed in detail.
