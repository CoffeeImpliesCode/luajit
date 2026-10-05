# luajit — LuaJIT 2.1 rolling, built from source with Zig

A Zig package for [LuaJIT](https://luajit.org/), the Just-In-Time compiler for
Lua. It compiles upstream's own C from `src/` in this repository — the whole
`$(LJVMCORE_O)` closure, the VM back end assembled from the `.dasc` sources,
and upstream's own host generators run for the target being built — and
publishes a typed Zig surface plus the complete raw C route.

| | |
|---|---|
| Upstream | LuaJIT, official project, `https://github.com/LuaJIT/LuaJIT` |
| Pin | `c6ffc141a8762b41703f9287d63d93622a13dd8f` |
| Release version | `2.1.1788856981` — **generated**, see below |
| Lua ABI | 5.1 (`LUA_VERSION_NUM 501`); GC64 on every 64-bit target |
| Toolchain | Zig 0.16.0 |
| Licence | MIT over upstream's files, public-domain donations inside the library, MIT over this fork's files — read [`NOTICE.md`](NOTICE.md) |

This README is the fork's. Upstream's own is preserved byte-for-byte as
[`README.upstream.md`](README.upstream.md).

**The version is not typed anywhere.** LuaJIT ships rolling releases: there is
no `v2.1.x` tag, and the released version of a commit *is* that commit's Unix
timestamp. This repository's committed `.relver` holds `1788856981`, the pinned
commit's timestamp, and upstream's `src/host/genversion.lua` substitutes it
into `src/luajit_rolling.h` to produce the generated `src/luajit.h`. That
header declares `LUAJIT_VERSION "LuaJIT 2.1.1788856981"` and exports the
identity symbol **`luaJIT_version_2_1_1788856981`**, which exists so that a
dynamic linker rejects a mismatch instead of letting it run.
[`UPSTREAM.md`](UPSTREAM.md) derives all four steps.

---

## 1. Native-source deviations

**None.**

Every byte under `src/`, `dynasm/`, `doc/`, `etc/`, `COPYRIGHT`,
`Makefile`, `.relver` and `.gitattributes` is upstream's, unmodified. No
upstream algorithm, header, table, manual or licence text was edited,
reformatted or re-indented.

The one file that is not byte-identical is the root `.gitignore`: upstream's
twelve lines are kept verbatim at the head and this fork's Zig block is
appended below them. It is the single path in the repository with no digest in
[`UPSTREAM.sha256`](UPSTREAM.sha256), and upstream's own digest is quoted in
that file's header.

`UPSTREAM.sha256` records the other **232** upstream files. Check it with:

```sh
sha256sum -c UPSTREAM.sha256
```

## 2. Native-build deviations

Upstream's build is `make`. This package does not run `make`, `src/Makefile`,
CMake or any other upstream build system, and downloads nothing. `build.zig`
is the whole build.

Four deviations, each with a reason:

1. **The object list is transcribed, not generated.** `build_support/sources.zig`
   is a copy of `src/Makefile:512-532` (`$(LJLIB_O)`, `$(LJCORE_O)`,
   `$(LJVM_O)`, `$(BUILDVM_O)`, `$(MINILUA_O)`, `$(LUAJIT_O)`) with each line
   range named beside it. Nothing is filtered. `ljamalg.c` — upstream's own
   amalgamation — is deliberately absent: it `#include`s the same sources and
   compiling it would define every symbol twice.
2. **The host generators run, on the host.** `src/host/README:2` requires it,
   and it is the only correct answer for a cross build: `host/buildvm` and
   `host/minilua` are compiled for the **build host** and executed there to
   produce inputs for the **target**. Every generated header is produced for
   the target being built, never for the machine running the generator.
3. **Two host inputs are checked in, not regenerated.**
   `src/host/minilua.c` and `src/host/buildvm_libbc.h` are upstream's shipped
   results of generators that need a Lua 5.1.5 source tree this repository
   does not carry and this SDK does not fetch. Both are in
   `UPSTREAM.sha256`.
4. **Install paths and metadata are generated from upstream's own files.**
   The six public headers are `Makefile:98`'s `$(FILES_INC)`; the nineteen
   `share/luajit-2.1/jit/*.lua` modules are `Makefile:99-104`'s
   `$(FILES_JITLIB)`, eighteen checked in and `vmdef.lua` generated; and the
   pkg-config file is `etc/luajit.pc` with `prefix=`, `multilib=` and
   `relver=` substituted exactly as `Makefile:86-91` does, including the
   Darwin variants. Nothing is invented here.

Dated history: [`CHANGELOG.md`](CHANGELOG.md), entries 1–8, all written
2026-10-04. The reasoning behind each, with its boundary, is in
[`FORK-NOTES.md`](FORK-NOTES.md).

### Build options

| Option | Values | Default | Meaning |
|---|---|---|---|
| `-Doptimize` | `Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall` | Zig's | passed to the native objects and to the Zig side alike |
| `-Dlinkage` | `static`, `dynamic` | `static` | static archive or real shared library; both install the same headers, modules, tool, manual and `luajit.pc` |
| `-Druntime` | `true`, `false` | `false` | resolve the native symbols through the platform loader at run time instead of linking the archive into the facade. The library is still built and installed either way — it is what a runtime build loads. |
| `-Dcpu` | Zig CPU model | Zig's | `baseline` for reproducible Nix builds |
| `-Dtarget` | Zig target triple | host | cross-compiles the whole closure, host generators included |
| `-Dlua-root` | absolute path | this build's resolved prefix, when it is absolute and outside the build cache | install root compiled in as `LUA_ROOT`/`LUA_LJDIR`/`LUA_MULTILIB` and into the delivered CLI's `package.path`; a relative value is refused, because `LUA_PATH_DEFAULT` is a runtime search path. It reaches no installed file: `luajit.pc` keeps `prefix=${pcfiledir}/../..`, so the installed metadata names its own location and nothing in it carries a build machine's root. A `b.dependency` child's prefix is a cache digest directory, and `install_root` refuses it |

The runtime route is **orthogonal to `-Dlinkage`** in the sense that matters: a
runtime-loaded build and a delivery linkage are separate questions, and all four
combinations exist. `build_support/graph.zig` is the only place the two differ,
and it is one `if`: with `-Druntime=true` the facade's `c` import is
`runtime/graph.zig`'s generated dispatch and **no archive is linked into it**;
otherwise it is `translate.createModule()` and the static library is linked.
`zig/root.zig` tells the two configurations apart with
`@hasDecl(c, "rt_runtime_loaded")`, so one facade source compiles either way and
a consumer never sees two incompatible shapes. `build.zig` declares the option,
defaults it to `false` and describes it in `zig build --help`.
`-Dcpu=baseline` is what `package.nix` passes so a Nix output does not inherit
whatever the builder happened to support.

## 3. Build, run and test matrix

Some gates have now been run and most have not, so the table records both and
says which is which. No row here is a success claim for a gate that has not
run, and a row that ran and failed is not a pass.

There is also **no historical evidence for this project to inherit.** Unlike
the SDKs that predate this migration, LuaJIT has no earlier receipt, no prior
53-platform run and no recorded failure. What follows is this tree's own first
build, and nothing more.

### What has actually been observed

* **Upstream's generator chain ran, and every generated input exists.** The
  host tools were compiled for the build host and executed there, and they
  produced the assembled VM (`src/lj_vm.S` → `lj_vm.o`) and **all six**
  generated headers — `host/buildvm_arch.h`, `lj_bcdef.h`, `lj_ffdef.h`,
  `lj_libdef.h`, `lj_recdef.h` and `lj_folddef.h` — together with the
  generated `src/luajit.h` and `src/jit/vmdef.lua`. None is hand-written and
  none is missing; `FORK-NOTES.md` § 3 has the chain in order.
* **The native closure compiles and links, after one missing dependency was
  named.** The first link attempt failed on **eight** missing APIs — six
  `_Unwind_*` entry points plus `__register_frame` and `__deregister_frame`,
  named one by one in [`UPSTREAM.md`](UPSTREAM.md#link-dependencies). Upstream's
  GCC driver supplies the external
  unwinder implicitly and Zig links C objects without that driver, so
  `build_support/graph.zig` now links `gcc_s` explicitly on the ELF Unix
  targets (`.linux`, `.hurd`, `.freebsd`, `.netbsd`, `.openbsd`,
  `.dragonfly`) — the same library that driver would have supplied. With that
  in place the library, the smoke example and the tests compile and link.
  `LUAJIT_UNWIND_EXTERNAL` was already defined for the same targets
  (`src/Makefile:325,343`), so the C side and the link side now agree.
* **`zig build test`, as last run in this tree: 29 tests, 5 pass, 2 fail, 22
  crashed.** That run predates the sanitizer flag below. The 53-cell matrix in
  the next section ran the same step on 42 further targets against a later
  source epoch and executed **no** passing cell, so this row is history rather
  than the current reading of `zig build test`.
* **The installed CLI was proved against an installed tree.** A driver probe
  recorded **4 of 4** steps passing at
  `/home/tmp2/gertullj/scratch/foundation-libs/luajit-cli-proof/evidence/20261004T213021Z/index.json`,
  against a prefix holding `lib/libluajit-5.1.a` and `bin/luajit`: the 19
  installed `jit` modules are 18 byte-identical to `src/jit` plus the
  generated `vmdef.lua`; the installed CLI byte-compiled a chunk with
  `jit/bcsave.lua` reached only through the installed `LUA_PATH`; a second
  process ran only the compiled chunk and printed 42; and nothing it read or
  executed changed while it ran. This is an external probe of an installed
  prefix, not the in-tree `native-test` step; that step's own observation is
  recorded in its own subsection below.
* **The MIPS R6 generator emits R6 encodings, and the C core still refuses
  this target.** A driver compile of `-Dtarget=mips64-linux-muslabi64
  -Dcpu=mips64r6 -Doptimize=ReleaseSafe`, recorded at
  `/home/tmp2/gertullj/scratch/foundation-libs/review-contract-probes/evidence/after-20261004T213021Z/luajit-r6-mips64-compile.json`,
  exits 1 on two diagnostics: the N64 `-fno-PIC` driver line, repeated once
  per translation unit, and the undeclared `__clear_cache` at
  `src/lj_mcode.c:56:3`. That is a boundary and it is upstream's own
  primitive. The generator half passes: 5610 encoded words from 1503 matched
  `.long` lines carry 63 R6 select forms and 0 R2 ones. A compile is not a run,
  and no R6 program was executed. [`FORK-NOTES.md`](FORK-NOTES.md) § 23 has
  the boundary.
* **The nested consumer build ran, and its command line is on record.** A
  driver ran `zig build consumer` for this SDK nine times in the
  nested-delivery-proof epoch `20261004T220323250122Z`, and every row passed:
  both linkages, linked and runtime-loaded, each with a default-target row and
  an explicit-target row, plus a refusal row. Each captured nested argv carried
  the caller's target, optimize, linkage and dispatch values, the named
  `-Dcpu`, the resolved `-Dlua-root`, `-j8 --summary all`, both caches and
  `--prefix`. The loaded rows reached their provider through `-- --provider`
  while `LUAJIT_TEST_PROVIDER` was absent from the child environment, and the
  refusal row exited 1 with the refusal its own source declares. Debug only, on
  one `x86_64` host. The receipt is the driver's; this row records what it
  observed.

### The one defect behind the crashes

Zig's Debug mode enables Clang's C undefined-behaviour sanitizers by default.
Upstream's pinned ULEB128 decoder at `src/lj_buf.c:298` writes
`(*w & 0x7f) << (sh += 7)`, and at `sh == 28` that promotes a signed byte and
shifts it into bit 31 — signed left-shift overflow in C, which the sanitizer
reports as it runs. `luaL_openlibs` reaches it, which is why the crash is
counted once per test that opens the libraries rather than once per build.

That is upstream's source and it stays byte-for-byte; the correction belongs
to the compiler flags, not to the source. `build_support/graph.zig` therefore
pins a narrow `-fno-sanitize=shift-base` on every native translation unit,
which turns off that one check and leaves the rest of the C UB instrumentation
on. **The suite has not been re-run since that flag landed**, so this is a
pending gate, not a fix known to work. Until it is re-run, no gate below may be
read as passing.

### The two failures that are not crashes

1. **`9007199254740993` comes back as `9007199254740992`.** A Lua 5.1 number is
   a `double` (`src/luaconf.h:119`). A string that reads as a number is
   scanned into a `lua_Number` (`src/lj_strscan.c:526-529`) and promoted to
   `lua_Integer` only when that double is already exact
   (`src/lj_api.c:437-444`); 2^53+1 has no `double`, so it is 2^53 by the time
   the integer is produced. This is the documented behaviour of the pinned
   source, and [`README.zig.md`](README.zig.md#numbers) states the boundary in
   full.
2. **The library-reported-globals test failed at run time.** The failure was
   observed; its cause was not re-established afterwards, so it is recorded as
   an open item rather than a diagnosis. Nothing in this repository claims to
   know which of the two it is.

### The source-bound 53-cell matrix and baseline, 2026-10-04/05

An external driver ran this SDK's 53 platform cells, and a second ran the
compile-only baseline. Both receipts carry one source identity, and that
identity is the boundary of every number below. Every cell ran the same command
shape — `zig build test -Dtarget=<triple> -j8 --prefix … --summary all --color
off --test-timeout 1800s` — with no extra `-D` configuration, so there is no
linkage or dispatch axis to read out of this matrix.

| Gate | Receipt | Result |
|---|---|---|
| 53-cell platform matrix | `resume-8-evidence/20261004T221720228710Z-45046/luajit-53-target-8.json` | **53 cells, `pass 0`, `build_only 11`, `build_fail 39`, runtime `fail 3`, run exit 1.** **No cell executed this SDK's suite and passed.** |
| Compile-only baseline | `baselines-and-configs/20261005T014547Z-797a73f2/receipts/baseline-luajit-check-2026-10-05T01-45-53Z.json` | exit 0, `failed: false`. `check` compiles and runs nothing, so no test number may be read out of it |
| Native route, 8 cells | `native-final-evidence/20261004T233628757747Z-69351/run.json` | 8 of 8 passed |
| Own-provider loaded route, 8 cells | `loaded-final-evidence/20261004T232823091897Z-23133/run.json` | 8 of 8 passed, against this SDK's own shared object |

`build_only` is compiled-not-run and is **never** a test pass. The 42 red cells
fall into four groups, and the groups are not interchangeable:

* **16 cells are upstream's own architecture refusal, and they are the
  expected answer.** Thirteen stop at `abi.zig:313` with
  `error.ArchitectureNotSupported` — upstream's `#error` at `lj_arch.h:69` —
  for `armeb-linux`, `armeb-netbsd`, `hexagon-linux`, `loongarch64-linux`,
  `powerpc64le-freebsd`, `powerpc64le-linux`, `riscv32-linux`,
  `riscv64-freebsd`, `riscv64-linux`, `riscv64-openbsd`, `s390x-linux`,
  `thumbeb-linux` and `wasm32-wasi`. The other three stop at `abi.zig:266`
  with `error.Ppc64NotSupported`, which is `lj_arch.h:369-370`, for
  `powerpc64-freebsd`, `powerpc64-linux` and `powerpc64-openbsd`. Neither is
  fixable in this fork.
* **16 cells are this fork's own host-generator loader. The defect is real, the
  fix has landed, and nothing is verified yet.** `graph.zig:619` forced
  `.abi = .musl` on the 32-bit host generator, so `buildvm` was built against
  `/lib/ld-musl-i386.so.1` and an x86-64 glibc host could not run it: *the host
  system is unable to execute binaries from the target because the host
  dynamic linker is `/lib64/ld-linux-x86-64.so.2`, while the target dynamic
  linker is `/lib/ld-musl-i386.so.1`*. The affected cells are `arm-freebsd`,
  `arm-linux`, `arm-netbsd`, `arm-openbsd`, `mips-linux`, `mipsel-linux`,
  `mips-netbsd`, `mipsel-netbsd`, `powerpc-linux`, `powerpc-netbsd`,
  `powerpc-openbsd`, `thumb-linux`, `x86-linux`, `x86-netbsd`, `x86-openbsd`
  and `x86-windows`. **The host generator on 32-bit Linux is now linked as a
  static executable rather than against a target libc**, which is what removes
  the declared-static-host-musl32 versus actual-dynamic-`ENOENT` discrepancy.
  **No gate has run against that correction**: not these sixteen cells, not the
  three-cell host probe, and not a 53-cell replay. A landed correction is not a
  result, so the row above stays exactly as recorded and **no cell of this
  matrix is claimed to have moved**.
* **7 cells are compiler- or upstream-bound.** Three stop compiling the
  generator — `src/vm_arm64.dasc:1953:72: error: no member named 'J' in
  'GG_State'`, through `src/lj_dispatch.h:122`'s `GG_DISP2J` — for
  `aarch64-maccatalyst`, `x86_64-maccatalyst` and `thumb-windows`. Four stop at
  `src/lj_mcode.c:56:3: error: call to undeclared function '__clear_cache'` for
  `mips64-linux`, `mips64el-linux`, `mips64-openbsd` and `mips64el-openbsd`,
  which is the same primitive the MIPS R6 probe below already records.
* **3 cells are runtime failures on the musl triples, and the cause is
  inherited.** `x86_64-linux`, `aarch64-linux` and `aarch64_be-linux` — each a
  bare `*.linux…musl` triple — built and ran 29 tests and then failed them.
  The recorded diagnosis is `ffi.C` reaching `dlsym` on musl; **that diagnosis
  was not re-derived for this matrix**, and the receipts carry the aggregate
  failure rather than the symbol. It is recorded as an open item, not a
  conclusion.

**What this matrix does not cover.** The counts above are the
`20261004T221720228710Z-45046` cohort and are **pre-host-fix**: they describe
the tree as it stood before the static-host-generator linkage landed, and that
run's `source_unchanged: true` speaks only to its own run. Nothing after it —
the host-generator correction above, or any later build-graph edit — is
retroactively covered by these numbers.

### The delivered CLI's own self-check, re-run against a fresh prefix

`zig build native-test` against a brand-new prefix reports **49 of 49 steps, 0
failures**: 15 stopped traces, `ffi.C.sqrt(16)` = 4, the dumped chunk reloaded
and returned 42, and `jit.vmdef`, `jit.bc` and `jit.dump` all loaded from the
fresh install. That install carries the **19 `jit` modules** — 18
byte-identical to `src/jit` plus the generated `vmdef.lua` — which is what the
installed-CLI probe above also counted. An earlier install probe reported 47 of
47, and `CHANGELOG.md` entry 20 added the module checks that did not run before
that; the earlier count is history, not a second current result. GC64 remains a
link-time boundary and not a compile flag: `src/lib_ffi.c:759-761` reports
`"gc64"` in the FFI version string, so a provider can be asked which mode it is
in, and an x64 non-GC64 build exports the same symbols and must not be mixed
with this one (`README.zig.md`, "Boundaries a consumer must not cross").

### What is still pending

| Gate | Command | Status |
|---|---|---|
| Native library compile and link | `zig build` | `OBSERVED-PARTIAL` — the closure, the smoke example and the tests compile and link; the whole default step has not been run end to end |
| Tests, Debug | `zig build test` | `OBSERVED-FAIL` — 29 tests: 5 pass, 2 fail, 22 crashed |
| Tests, Debug, after the sanitizer flag | `zig build test` | `PENDING-VERIFICATION` |
| Tests, ReleaseSafe | `zig build test -Doptimize=ReleaseSafe` | `PENDING-VERIFICATION` |
| Example program | `zig build smoke` | `PENDING-VERIFICATION` — compiled; not recorded as run |
| The delivered CLI's own self-check | `zig build native-test` | `OBSERVED-PASS` against a brand-new prefix — 49 of 49 steps, 0 failures; see "The delivered CLI's own self-check" above |
| Two C TUs compiled, linked and **run** against the installed tree | `zig build header-check` | `PENDING-VERIFICATION` |
| Compile-only baseline, six targets, four optimize modes | `zig build check` | `PENDING-VERIFICATION` |
| Dependent package | `zig build consumer` | `OBSERVED-PASS` — nine nested cases in Debug on one host: both linkages, linked and runtime-loaded, default and explicit target, plus the refusal case. Other optimize modes and other hosts are still unrun |
| Static and shared, all four optimize modes | `zig build install -Dlinkage=static\|dynamic` | `PENDING-VERIFICATION` |
| Runtime-loaded consumers | `zig build test -Druntime=true` and its consumers | `PENDING-VERIFICATION` — the route is declared and wired; no runtime-loaded build has been run |
| Upstream integrity | `sha256sum -c UPSTREAM.sha256` | `PENDING-VERIFICATION` |
| Nix static and shared derivations | `nix build .#static` / `.#shared` | `PENDING-VERIFICATION` |
| Canonical devenv shell | `devenv shell` | `PENDING-VERIFICATION` |
| Installed C consumer, fetched Zig consumer | driver-owned | `PENDING-VERIFICATION` |
| 53-platform cross matrix | `cross-test` | `OBSERVED-FAIL` on the `20261004T221720228710Z-45046` **pre-host-fix** cohort — 53 cells, **0 executed passes**, 11 `build_only`, 39 build failures, 3 runtime failures; see "The source-bound 53-cell matrix and baseline" above. The 16 host-generator loader rows now sit behind `CHANGELOG.md` entry 27's static-host-generator linkage, which is **landed and unverified**: a three-cell host probe and then a 53-cell replay are owed before any of those sixteen reads as fixed |
| Installed CLI probe, epoch `20261004T213021Z` | external, `luajit-cli-proof` | `OBSERVED-PASS` — 4 of 4 steps; receipt path above |
| MIPS R6 codegen, epoch `20261004T213021Z` | external, `-Dtarget=mips64-linux-muslabi64 -Dcpu=mips64r6` | generator `OBSERVED-PASS` (63 R6 select forms, 0 R2); native compile `OBSERVED-BOUNDARY` on `__clear_cache`; nothing run |

`OBSERVED-PARTIAL` means part of the step ran and is recorded above; it is not
a pass. The driver fills the pending rows and re-runs the failed ones; the two
failures above are inputs to that work, not results to be explained away.

The six compile-only baseline targets are `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `aarch64-macos-none`, `x86_64-windows-gnu`,
`riscv64-linux-gnu` and `wasm32-wasi`. **Compiling** a foreign target is build
coverage, not a passing test, and a build-only cell is recorded as build-only.

**Two of the six are refused by upstream itself, and that refusal is the
expected result.** `src/lj_arch.h:54-70` selects one of x86, x64, arm, arm64,
ppc, mips32 and mips64, and its `#else` at `lj_arch.h:69` is `#error
"Architecture not supported (in this version), see: https://luajit.org/status.html#architectures"`.
`riscv64-linux-gnu` and `wasm32-wasi` are not in that list, so the `check`
step runs each target's own preprocessor over `src/lj_arch.h` and **requires**
upstream's refusal — a non-zero exit with that message on stderr. Neither
target is dropped and neither is faked: a cell that passes because upstream
refused it is an observed boundary, recorded as such, not as coverage.

`package.nix` declares `meta.platforms = lib.platforms.unix` because nothing
here has produced a `.dll` or an import library yet; that is a statement about
what has been observed, not a verdict about what the source can compile.

`.fingerprint` is `0x0` in `build.zig.zon`, and that is a deliberate
placeholder, not a value. The correct value is printed by the compiler in its
own `invalid fingerprint ... use this value` diagnostic on the first build; no
hash was invented here, and the driver takes it from that message.

## 4. Consumption

### The canonical way in: devenv

```sh
devenv shell          # or let direnv do it through .envrc
```

The shell holds **tools only** — Zig 0.16.0, pkg-config, git. The library is
not in it, because entering a shell should not build a library.

Namespaced tasks, run with `devenv tasks run <name>`. Every build task first
changes into this SDK's own root, then runs with `-j8 --summary all` and
`--cache-dir "$ZIG_LOCAL_CACHE_DIR/native"`, so nothing is generated inside the
checkout. Only the install entries take a `--prefix`, because `test`, `smoke`,
`check` and `consumer` are wired to no install step (`build.zig:393`, `:402`,
`:409`, `:417`). A caller-exported `ZIG_LOCAL_CACHE_DIR` or
`ZIG_GLOBAL_CACHE_DIR` is used as it stands; a task fills only what is unset,
from `XDG_CACHE_HOME` and then `TMPDIR`, and exits 1 rather than guess a
location. Nothing forwards extra arguments — devenv 2.4's `TasksRun` passes
none — and `sdk:integrity` takes the root change and none of the rest.

| Task | What it runs |
|---|---|
| `sdk:build` | `zig build install --prefix "$ZIG_LOCAL_CACHE_DIR/prefix"` |
| `sdk:test` | `zig build test` |
| `sdk:test-release-safe` | `zig build test -Doptimize=ReleaseSafe` |
| `sdk:smoke` | `zig build smoke` |
| `sdk:check` | `zig build check` |
| `sdk:consumer` | `zig build consumer` |
| `sdk:integrity` | `sha256sum -c UPSTREAM.sha256` |
| `sdk:gate` | all of the above, in order |

`zig build consumer` runs `consumer/` as its own `zig build`. `runConsumer`
in `build.zig` gives that build this graph's own selections instead of letting
it resolve its own: the target query, the optimize, linkage and dispatch-mode
values, the CPU when a `-Dcpu` was named, and the resolved `-Dlua-root`. Both
caches travel, the local one with a `consumer` subdirectory so two build graphs
do not write one manifest directory and the global one whole because it is
shared by contract. `-j8 --summary all` travel with them, and so do the
enabled executor switches and `--libc-runtimes`. The caller's own `--prefix`
travels when it is not this build's `zig-out`, made absolute first because the
nested build's working directory is `consumer/`. Everything the caller typed
after `--` is program argv, not build configuration: it crosses the hop behind
`--` and `consumer/build.zig` passes its own `b.args` to `run_exe`, so
`zig build consumer -Druntime=true -- --provider <path>` reaches the provider
name that `consumer/src/main.zig` reads. The step asks the nested build for
`run` when this host can execute the selected target and for `install` when it
cannot: `hostCanExecute` in `build.zig` asks `std.zig.system.getExternalExecutor`,
the question `std.Build.Step.Run` asks about the binary it is about to spawn, and
an external executor counts only where the build runner was told that executor
may be used. A target with no enabled executor builds and installs instead,
which is build coverage and never a passing consumer.

Packaging is a build, not a shell entry:

```sh
devenv build outputs.static     # package.nix with -Dlinkage=static
devenv build outputs.shared     # package.nix with -Dlinkage=dynamic
```

### Nix

```sh
nix build .#static
nix build .#shared
```

`flake.nix` and `devenv.nix` both reach the same `pkgs.callPackage ./package.nix`
derivation; neither reimplements it. `packages.<system>.default` is the static
variant, because static is this SDK's linkage policy. There is no
`luajit-static`/`luajit-shared` alias pair — the variant is the attribute name.

`nix develop` gives a tools-only shell from a plain flake checkout.
`devenv shell` remains canonical; `nix develop` is not claimed to have been
run.

### As a Zig dependency

The build graph publishes a public module named **`luajit`**, and
`zig/root.zig` publishes `pub const c = @import("c")` alongside its typed
surface. [`README.zig.md`](README.zig.md) is the interface reference: the typed
API, the raw route, the runtime-loading entry points, and the external ABI
families a loaded provider must satisfy.

### What an installed output contains

| Path | What |
|---|---|
| `lib/libluajit-5.1.a` | the static variant |
| `lib/libluajit-5.1.so.2.1.1788856981`, with `libluajit-5.1.so.2` and `libluajit-5.1.so` symlinks | the shared variant |
| `include/luajit-2.1/{lua.h,lualib.h,lauxlib.h,luaconf.h,lua.hpp,luajit.h}` | the six public headers, `luajit.h` generated |
| `share/luajit-2.1/jit/*.lua` | the eighteen checked-in modules plus the generated `vmdef.lua` |
| `bin/luajit` | the front end |
| `share/man/man1/luajit.1` | the manual page |
| `lib/pkgconfig/luajit.pc` | `prefix=${pcfiledir}/../..`, `libname=luajit-${abiver}` (which `pkg-config` expands, not the file), `relver=1788856981`, and `Libs.private: -Wl,-E -lm -ldl -lgcc_s` on the six ELF Unix targets the graph links `gcc_s` for, upstream's three flags on every other target |
| `share/doc/luajit-2.1/COPYRIGHT` | upstream's three grants, verbatim |
| `share/doc/luajit-2.1/README.md` | this file |
| `share/licenses/luajit/{NOTICE.md,FORK-LICENSE.md,UPSTREAM.md,README.upstream.md}` | the licence audit, the fork's grant, the pin record, and upstream's README verbatim |

Every one of those names is upstream's own (`Makefile:56-71`, `:98-104`,
`:133-146`), except two differences the build graph records and does not hide:
`make install` also creates the versioned alias `bin/luajit-2.1.<relver>` as a
symlink, which Zig's install step cannot create, and upstream's
`$(INSTALL_LMODD)`/`$(INSTALL_CMODD)` (`Makefile:47-50,75`) are two empty
directories for Lua and C modules that upstream creates and never fills, which
this build does not create at all.

The Nix output is that same install tree: `zig build install` writes every file
above, licence and provenance records included, and `package.nix` contributes
the prefix, the Zig caches under `$TMPDIR` and the flags. So
`nix build .#static` and `nix build .#shared` deliver the same files a local
`zig build install --prefix …` does, and the derivation's `installCheckPhase`
asserts every one of those paths — which makes it a check on the build graph,
not on the wrapper.

A C consumer links with `-lluajit-5.1` and includes
`<luajit-2.1/lua.h>`, or lets `pkg-config --cflags --libs luajit` say so.

### Runtime loading

`-Druntime=true` swaps the translated native module for one whose selected
externs resolve through a process-lifetime table loaded once, explicitly, from
either an absolute file path or an explicit basename. There is no path-to-
system fallback and no automatic retry. Linked builds are unaffected and stay
direct. The full contract, including what a provider must actually satisfy
beyond having the right symbols, is in
[`README.zig.md`](README.zig.md#runtime-loading).

### Boundaries a consumer must not cross

* This is a **Lua 5.1** implementation. It is not ABI-compatible with Lua 5.4
  or later, and no part of it may be substituted for the Lua 5.5 SDK in this
  workspace or the other way round.
* **`lua_Number` is `double`, so every Lua number is an `f64`**
  (`src/luaconf.h:118-119`). That is a single width on every target, and it is
  the width a value is rounded to whenever it becomes a number.
* **`lua_Integer` is `ptrdiff_t`** (`src/luaconf.h:106`) — 64 bits on a
  64-bit target, 32 bits on a 32-bit one — so `lua_Integer` is *the target's
  scalar*, not one width across the supported targets. It is also **not a
  full-precision guarantee**: a value that reaches Lua as a number, or that is
  scanned out of a string, has already been a `double`, and 2^53+1 does not
  survive that. An exact integer only stays exact when it was pushed as one
  (`pushInteger`) and is read back with `toIntegerX`. The full rule, with the
  source lines, is [`README.zig.md`](README.zig.md#numbers).
* **GC64 is on for every 64-bit target** — arm64 and mips64 unconditionally,
  x64 by default and refused on macOS (`src/lj_arch.h:216-220,303,459`). The
  32-bit architectures run the non-GC64 VM. It is a link-time boundary: an x64
  non-GC64 build exports the same symbols and must not be mixed with this one.
* **Allocator ownership.** `State.init` opens through `luaL_newstate`, so the
  library's own pooled allocator is installed and the caller owns nothing.
  `State.initWithAllocator` hands LuaJIT a callback and a user pointer, and
  both are the caller's until `deinit`. `setAllocator` returns the pair it
  replaced and frees nothing, so a caller that swaps an allocator in owns
  putting it back before `deinit`: `lua_close` releases every remaining block
  through whatever callback is installed at that moment, and destroys the
  library's pool only while the library's own callback is still the installed
  one. The pairing rule (`osize == 0 && nsize == 0` is the only release) and
  the `AllocatorPair` nominal type are in
  [`README.zig.md`](README.zig.md#allocation).
* **Thread and lifetime ownership.** One `State` belongs to one thread at a
  time, exactly as in C; there is no lock in it. A `Thread` is a coroutine the
  parent state owns and keeps alive only because the creating call pushed it —
  dropping that stack slot and collecting leaves the handle dangling. `deinit`
  releases everything at once, and calling it twice is a no-op the second time;
  calling it while a `Thread` or `Buffer` is still in use is a use after free
  that nothing here can detect. A `State{ .raw = l }` built from a pointer Lua
  handed a C function **borrows** and must not be `deinit`ed.
* `static` is an artifact, not a closure. The static variant still needs
  `-lm` and `-ldl`.

## Provenance and licence

| File | What it holds |
|---|---|
| [`README.upstream.md`](README.upstream.md) | upstream's README, byte-identical |
| [`UPSTREAM.md`](UPSTREAM.md) | the pin, the rolling-version derivation, the compiled closure, the host generators, the ABI facts |
| [`UPSTREAM.sha256`](UPSTREAM.sha256) | 232 digests and the reasons for every exclusion |
| [`NOTICE.md`](NOTICE.md) | the per-file licence audit: three upstream grants, ten public-domain files, the fourteen files with no notice |
| [`FORK-LICENSE.md`](FORK-LICENSE.md) | the owner's authorization and the MIT grant over this fork's own files |
| [`CHANGELOG.md`](CHANGELOG.md) | the numbered fork-only divergences |
| [`FORK-NOTES.md`](FORK-NOTES.md) | the decisions, what each cost, and the open items for the driver |
| [`README.zig.md`](README.zig.md) | the Zig interface reference |

No `flake.lock` and no `devenv.lock` are written here. Locks belong to whoever
operates the project, and no narHash has been invented for either.

This SDK is local and unpublished.

## Upstream README, verbatim

Upstream's own README is reproduced here exactly, at the end, because that is
where a reader should find it. The same bytes are also carried as
[`README.upstream.md`](README.upstream.md) and both have the same digest in
[`UPSTREAM.sha256`](UPSTREAM.sha256); nothing above this line has rewritten a
word of it.

```text
README for LuaJIT 2.1
---------------------

LuaJIT is a Just-In-Time (JIT) compiler for the Lua programming language.

Project Homepage: https://luajit.org/

LuaJIT is Copyright (C) 2005-2026 Mike Pall.
LuaJIT is free software, released under the MIT license.
See full Copyright Notice in the COPYRIGHT file or in luajit.h.

Documentation for LuaJIT is available in HTML format.
Please point your favorite browser to:

 doc/luajit.html
```
