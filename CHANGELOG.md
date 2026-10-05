# CHANGELOG

Fork-only divergences from upstream, numbered. Upstream's own history is not
reproduced here: this is a rolling snapshot with no tag, and its changes are
described by the commit, not by this file.

Every entry records what this repository changed and why. Status vocabulary is
the workspace's: `PENDING-VERIFICATION` for a landed correction with no
observation, `SOURCE-CONFIRMED` for a fact read out of a file, `OBSERVED-FAIL`
for a run that actually happened and did not pass, and `CONSTRAINT` for a
binding rule with nothing behind it.

Most entries in the 2026-10-04 wave are `PENDING-VERIFICATION`. Three are not:
the native closure has been compiled and linked, `zig build test` in Debug was
run once and **failed**, and everything that followed that run has not been run
at all. Driver probes have since been recorded outside this tree: an
installed-CLI proof and an attempted MIPS R6 compile in epoch
`20261004T213021Z`, and a nine-case nested consumer run in epoch
`20261004T220323250122Z`. Each says in its own entry what it observed and what
it did not. Those facts appear in the entries that describe them and nowhere
else; the authoritative table is
[`README.md`](README.md#3-build-run-and-test-matrix).

---

## 1 — Initial import of the production rolling snapshot

**2026-10-04. `SOURCE-CONFIRMED`.**

Imported the official LuaJIT project at commit
`c6ffc141a8762b41703f9287d63d93622a13dd8f`, acquired from
`https://codeload.github.com/LuaJIT/LuaJIT/tar.gz/`, archive SHA-256
`6e5fec07750add912e7c3eae0c194d24cd6d023714e1f04a0298a5b4819e4457`. 233
files, no patch, no edit to any upstream byte.

Why a commit and not a release: LuaJIT ships **rolling releases**. There is no
`v2.1.x` tag after `v2.1.0-beta3`, so the released version of any commit *is*
that commit's timestamp. `UPSTREAM.md` derives it from the committed `.relver`
in four steps and names the resulting identity symbol.

Upstream's own `README` was preserved byte-for-byte as `README.upstream.md` at
the moment the fork's own `README.md` was created, so that a reader who wants
upstream's own words does not find them rewritten.

## 2 — Upstream files preserved unchanged

**2026-10-04. `SOURCE-CONFIRMED`.**

* `COPYRIGHT` — all three upstream grants verbatim. Nothing appended, nothing
  narrowed.
* `src/` — 194 files, including `lua.h`, `luaconf.h`, `lualib.h`, `lauxlib.h`,
  `lua.hpp`, `luajit_rolling.h`, all `lib_*.c`, all `lj_*.c`, every `.dasc`
  VM source, and every header.
* `dynasm/` — 14 files. DynASM 1.5.0 is part of the project and carries the
  project's own notice; it is not a separately-licensed vendored drop.
* `doc/` — 16 files.
* `etc/` — `luajit.pc` and `luajit.1`, the metadata and manual sources.
* `Makefile`, `src/Makefile`, `src/Makefile.dep` — upstream's build
  specification, kept and *read*, never run.
* `.gitattributes`, `.relver`, `src/.gitignore`, `src/host/.gitignore`,
  `src/jit/.gitignore` — kept verbatim.

`UPSTREAM.sha256` records 232 of them. The two hundred thirty-third, the root
`.gitignore`, is upstream's twelve lines with the fork's block appended below;
upstream's own digest is quoted in the record's header.

**What this costs:** the root `.gitignore` is the one file in the repository
with no digest of its own, because it has two grants in it. That is recorded in
`NOTICE.md` and `FORK-LICENSE.md` rather than papered over.

## 3 — Native build: upstream's C through Zig, with upstream's own generators

**2026-10-04. `PENDING-VERIFICATION`.**

`build.zig` compiles the complete upstream closure named by
`src/Makefile:512-532` — `$(LJVMCORE_O)`, which is 69 C translation units plus
the assembled `lj_vm.o` — with Zig 0.16.0. It runs no `make`, no
`src/Makefile`, no CMake, and downloads nothing. The list itself lives in
`build_support/sources.zig`, transcribed from those lines with the range named
beside each entry.

The generated inputs are produced the way upstream produces them, on the host
where upstream requires it:

| Generated | By | Runs on |
|---|---|---|
| `host/buildvm` | compiled from `buildvm.c` + four `buildvm_*.c` + the checked-in `buildvm_libbc.h` | build host |
| `host/minilua` | compiled from the **checked-in** `host/minilua.c` | build host |
| `host/buildvm_arch.h` | `host/minilua ../dynasm/dynasm.lua` | build host, **for the target being built** |
| `lj_bcdef.h`, `lj_ffdef.h`, `lj_libdef.h`, `lj_recdef.h`, `lj_folddef.h` | `host/buildvm -m bcdef/ffdef/libdef/recdef/folddef` | build host, for the target |
| `src/jit/vmdef.lua` | `host/buildvm -m vmdef` | build host, for the target |
| `src/luajit.h` | `host/minilua src/host/genversion.lua` | build host |
| `src/lj_vm.S` → `lj_vm.o` | `host/buildvm -m elfasm/machasm/peobj`, then the assembler | build host, for the target |

Two of those inputs are **checked in, not generated**:
`src/host/minilua.c` and `src/host/buildvm_libbc.h`. `genminilua.lua` and
`src/Makefile:642-644`'s `libbc` target both need a Lua 5.1.5 source tree this
repository does not carry and this SDK does not fetch. Upstream ships both
results; both have digests.

`src/host/README:2` requires the host tools to run on the host, not the
target, and `AGENTS.md` § 5 requires every target-dependent generated header to
be produced *for the target*. `host/buildvm_arch.h` is DynASM's output from
target macros and selects the back end, the jump range and the page size; a
host copy copied onto a cross target would generate the wrong VM.

**The rolling version is generated, never typed.** The build reads the
committed `.relver`, runs `genversion.lua`, and writes `src/luajit.h` with
`LUAJIT_VERSION "LuaJIT 2.1.1788856981"` and
`LUAJIT_VERSION_SYM luaJIT_version_2_1_1788856981`. `build.zig.zon` carries the
same string in `.version`, derived from `.relver` rather than typed.

**What this costs:** the host generator chain is the largest single piece of
this build. It is also the only way to build LuaJIT at all — there is no
pre-generated `luajit.h` to ship and no amalgamation that avoids it.

## 4 — Two linkage variants, one SDK

**2026-10-04. `PENDING-VERIFICATION`.**

`-Dlinkage=static|dynamic` selects the build graph's delivery mode. The
default is `static`, which is this SDK's linkage policy. Both variants install
the same headers, the same `src/jit/*.lua` modules, the same `luajit` tool,
the same `COPYRIGHT` and the same `luajit.pc`, so a consumer's compile line
does not change when the artifact does.

Shared builds keep upstream's export macros as written
(`src/luaconf.h:135-136`), because `LUA_API` is the mechanism that makes the
public API visible and getting it wrong exports nothing at all.

**What this costs:** nothing in the interface. The two variants differ only in
the artifact a linker is pointed at.

## 5 — `-Druntime` runtime loading, orthogonal to linkage

**2026-10-04. `PENDING-VERIFICATION`.**

`-Druntime=true` swaps the translated native module for one whose selected
externs resolve through a process-lifetime table. It is a separate switch from
`-Dlinkage`: a runtime-loaded build and a delivery linkage are independent
questions. Linked calls stay direct — a runtime build with no explicit load
panics before the first call, in every optimize mode.

**What this costs:** the runtime branch is a second code path through the same
extern surface, and it has to keep the translated types nominally identical
rather than re-declaring them.

## 6 — Typed Zig surface and the raw route

**2026-10-04. `PENDING-VERIFICATION`.**

`zig/root.zig` publishes `pub const c = @import("c")` — the whole translated
native surface, not only what the typed helpers call — plus a documented typed
layer over state ownership, the standard libraries, protected chunk evaluation,
stack values and error retrieval. `README.zig.md` is the reference and is kept
in step with the source.

The Lua 5.1 ABI boundary is documented, not smoothed over: `lua_Integer` is
`ptrdiff_t`, `lua_Number` is `double`, and GC64 is on for every 64-bit target.
A consumer must not assume Lua 5.5 semantics; this is a different ABI.

**What this costs:** a typed layer over a C API with a `lua_Number` that is
always a `double` has nowhere to hide a numeric conversion, so every one of
them is at the boundary where a silent narrowing could happen.

## 7 — Packaging: one source-only derivation, three entry points

**2026-10-04. `PENDING-VERIFICATION`.**

`package.nix` is a single uncurried derivation taking
`{ lib, stdenv, pkgs, zig, linkage, optimize }`. `flake.nix` and `devenv.nix`
both reach it with `pkgs.callPackage`; neither reimplements it and neither
reads the other's package path. The variants live in the entry points, named
`static`, `shared` and `default`.

`devenv.nix` exposes `outputs.static` and `outputs.shared` as **lazy**
attributes pointing at the same derivation, so entering the shell does not
build the library. The shell holds tools only.

The derivation installs `ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR` under
`$TMPDIR`, passes `-j"${NIX_BUILD_CORES:-1}"`, `-Dcpu=baseline`, one
`-Doptimize`, one `-Dlinkage` and `--prefix "$out"`, and installs the fork's
provenance material beside what the build graph already installed — one writer
per path.

**What this costs:** cross-compilation from Nix is refused rather than guessed
at, with an explicit `stdenv.hostPlatform.system`/`buildPlatform.system`
comparison. A remote builder is unaffected; a genuine cross derivation would
have to name the Zig target itself.

## 8 — Provenance: digests, licence audit, grant

**2026-10-04. `PENDING-VERIFICATION`.**

`UPSTREAM.sha256` (232 records), `UPSTREAM.md`, `NOTICE.md` and
`FORK-LICENSE.md` were written together. The audit is complete rather than
sampled: every shipped upstream file was classified by the notice in its own
bytes.

Two findings the audit turned up that a single label would have lost:

* `COPYRIGHT` carries **three** grants, not one — LuaJIT's MIT, Lua.org's MIT
  over the Lua 5.1/5.2 code, and Doug Lea's public-domain dlmalloc notice.
* **Ten** files were donated to the public domain, and **four of them are
  inside the compiled closure** (`src/lj_alloc.c`, `src/lj_char.c`,
  `src/lj_char.h`, `src/lj_alloc.h`). A binary built from this source contains
  public-domain code, and MIT's notice condition does not reach those bytes.

The fork's own files are under MIT, the owner's authorization for that choice
being recorded in `FORK-LICENSE.md`.

## 9 — Two defects found in review and corrected before any gate

**2026-10-04. `SOURCE-CONFIRMED` (the defect), `PENDING-VERIFICATION` (the
fix).**

Both were found by reading the typed source against the pinned C headers, both
were reported to the owning role and to the driver, and both were corrected in
place before this repository was documented. `FORK-NOTES.md` § 11 has the full
condition/symptom/resolution/bound for each; this entry records that they
happened.

1. **The load-time validation treated `lua_version()` as a string.**
   `src/lua.h:351` declares it as `const lua_Number *` and `src/lj_api.c:136-140`
   returns a pointer to a static `double` holding `LUA_VERSION_NUM`. Reading
   those eight bytes as `[*:0]const u8` produced a two-byte span that can never
   start with `"Lua 5.1"`, so **every** runtime load would have been refused
   with `ValidationFailed` — including a load of this SDK's own library.
   Corrected to compare the pointed-to value against
   `@floatFromInt(LUA_VERSION_NUM)`, both sides from the translation.
2. **`Thread` re-created its coroutine instead of naming it.**
   `lua_newthread(L)` constructs and pushes; it never looks up. A `raw()`
   method built on it returned a different coroutine on each call, and a
   fallback path pushed a thread it never recorded. `Thread` is now a
   `raw: ?*c.lua_State` field holding the pointer returned **at creation**,
   with `resume`, `status` and `errorMessage` over it and no lookup path to get
   wrong.

**What this costs:** nothing in the delivered interface, and both were
behavioural rather than cosmetic — a wrong answer from a runtime load and a
wrong object identity from a coroutine handle are exactly the two things a
test that only checks "it compiled" will not catch.

## 10 — The runtime route became a declared build option

**2026-10-04. `PENDING-VERIFICATION`.**

`-Druntime=true` no longer depends on somebody hand-editing the build graph. It
is a `b.option` in `build.zig`, defaults to `false`, and
`build_support/graph.zig` branches on it in one place: the runtime branch
imports `runtime/graph.zig`'s `createModule(b, translate, target, optimize)` as
the facade's `c` and links **no** archive into it; the linked branch imports
`translate.createModule()` and links the static library. The library is built
and installed either way, because it is what a runtime build loads.

The shared core an earlier draft described as absent is in the tree:
`runtime/loader.zig`, `runtime/generate.zig`, `runtime/sync.c`,
`runtime/sync.h`, plus this SDK's `runtime/graph.zig` and
`runtime/library.zig`. `zig/root.zig` needs no second source — it asks which
configuration it was compiled against with
`@hasDecl(c, "rt_runtime_loaded")` and reads `LoadSource` and `LoadError` off
whichever module defines them.

**What this costs:** the runtime branch is a second shape for the same extern
surface, and it has to keep the translated types nominally identical rather than
re-declaring them. It also carries one sharp edge that is a caller constraint
and not a build-graph one: linking the compiled archive into any module that
imports the dispatch lets the linker resolve the symbols statically and turns
the runtime route back into a linked one with no error at all.
`FORK-NOTES.md` § 12 has the reasoning and the bound.

## 11 — The external unwinder became an explicit link dependency

**2026-10-04. `PENDING-VERIFICATION` for the dependency; `OBSERVED-PARTIAL` for
the link it fixed.**

The first link attempt of the native closure failed on **eight** undefined
symbols: `_Unwind_GetCFA`, `_Unwind_SetGR`, `_Unwind_GetIP`, `_Unwind_SetIP`,
`_Unwind_DeleteException`, `_Unwind_RaiseException`, `__register_frame` and
`__deregister_frame`. Upstream declares all eight under `LJ_UNWIND_EXT`
(`src/lj_arch.h:717-721`) and defines none of them; they are the Itanium C++
ABI unwinder, and libgcc provides it.

Upstream's `Makefile` never names that library and `etc/luajit.pc` never lists
it, because a GCC or Clang driver links it in by default. Zig compiles C objects
without that driver, so `build_support/graph.zig` now links `gcc_s` explicitly
on the ELF Unix targets — `.linux`, `.hurd`, `.freebsd`, `.netbsd`, `.openbsd`,
`.dragonfly` — which is the same library the driver would have supplied. The C
side already carried `-DLUAJIT_UNWIND_EXTERNAL` for those targets, from
`src/Makefile:325` on Darwin and `:343` for any toolchain whose objects always
carry unwind tables, so the macro that asks for the unwinder and the library
that satisfies it now agree. With that in place the library, the smoke example
and the tests compile and link.

`_Unwind_Find_FDE` is deliberately not one of the eight: it is behind
`defined(LUA_USE_ASSERT)` (`src/lj_err.c:501`), and this build defines neither
`LUA_USE_ASSERT` nor `LUA_USE_APICHECK`.

**What this costs:** one system library on six targets, and an installed
`luajit.pc` that understated the real link line. The understating was upstream's
metadata and the rendered file inherited it, so the first version of this entry
recorded it as not correctable here. Entry 18 corrects the rendered file
instead, which changes what `pkg-config --static --libs` hands a consumer and
no upstream byte: `etc/luajit.pc` is read and rewritten here, never copied.
`FORK-NOTES.md` § 13 has the condition, the symptom and the bound; § 20 has
the metadata correction.

## 12 — One C sanitizer check is off for upstream's own bit decoder

**2026-10-04. `OBSERVED-FAIL` before the flag; `PENDING-VERIFICATION` after
it.**

Zig's Debug mode enables Clang's C undefined-behaviour sanitizers. The pinned
ULEB128 decoder at `src/lj_buf.c:298` reads `(*w & 0x7f) << (sh += 7)`, and at
`sh == 28` that promotes a signed byte and shifts it into bit 31 — signed
left-shift overflow, reported by the sanitizer as the decoder runs.
`luaL_openlibs` reaches it, so the report arrives once per test that opens the
libraries rather than once per build.

That line is upstream's and stays byte-for-byte, so the correction belongs to
the compiler flags and nowhere else. `build_support/graph.zig` adds
`-fno-sanitize=shift-base` to every native translation unit: that single check
off, every other C undefined-behaviour check still on. No bare
`-fno-sanitize`, no `-fsanitize-recover`, and no `LUA_USE_ASSERT` — the intent is
to match upstream's unsanitized bit-decoding semantics, not to stop looking.

**The suite has not been re-run since that flag landed.** This entry records a
correction that has not been observed, not a correction known to work, and no
row of the gate table may be read as passing until it is re-run.

## 13 — What the first build and test run reported

**2026-10-04. `OBSERVED-PARTIAL` for the build; `OBSERVED-FAIL` for the tests.**

Recorded because the gate table is the authority and this is its changelog copy.
Neither half of this entry is a pass.

* **Generated inputs: complete.** The host generators ran on the build host and
  produced the assembled VM plus **all six** generated headers —
  `host/buildvm_arch.h`, `lj_bcdef.h`, `lj_ffdef.h`, `lj_libdef.h`,
  `lj_recdef.h` and `lj_folddef.h` — together with `src/luajit.h` and
  `src/jit/vmdef.lua`.
* **Native closure: compiles and links**, once the unwinder in entry 11 is
  named. The library, the smoke example and the tests all build.
* **`zig build test`, Debug: 29 tests, 5 pass, 2 fail, 22 crashed.** The 22 are
  the single sanitizer finding in entry 12. Of the other two, one is Lua 5.1's
  own `double` boundary — the string `9007199254740993`, which is 2^53+1, comes
  back as `9007199254740992`, because a string that reads as a number is scanned
  into a `lua_Number` and promoted to `lua_Integer` only when that double is
  already exact (`src/lj_strscan.c:526-529`, `src/lj_api.c:437-444`). The second
  is the library-reported-globals test: the failure was observed, its cause was
  not re-established, and it is recorded as an open item rather than a
  diagnosis.
* **Nothing else has been run.** `zig build` end to end, `test` in ReleaseSafe,
  `smoke`, `native-test`, `header-check`, `check`, `consumer`, the runtime
  route, the Nix derivations, `sha256sum -c UPSTREAM.sha256` and the
  53-platform cross matrix are all unobserved.

**What this costs:** nothing in the source, and a great deal in confidence. A
suite whose majority of tests had not executed is not a suite that has been
validated, and the two surviving failures are inputs to the next run rather than
results to be explained away.

## 14 — `libc_noise` was measured instead of read off a header

**2026-10-04. `PENDING-VERIFICATION`.**

`runtime/graph.zig`'s `libc_noise` is the list of `extern` declarations the C
library provides, which the generator must leave `direct` rather than route to
the provider. The previous list was 280 names, and it omitted `stdin`,
`stdout` and `stderr`: `src/lauxlib.h:13` reaches `<stdio.h>`, every one of
these libcs declares the three stream objects, and `src/lua.h:92-95`'s
`LUA_USER_H` is not defined so nothing else in the four public headers pulls
them in. A `-Druntime=true` load therefore demanded the three from
`libluajit-5.1` itself. On Linux that often resolved by accident, because
`dlsym` on the provider's handle also searches its dependencies and libc is
one; it is wrong for a provider that does not pull libc in — a fully static
object, Windows, a minimal provider — which is where it fails.

The list is now the measured closure rather than a reading of four headers.
The pinned Zig 0.16.0 `zig translate-c` was run over this package's aggregate
translation unit, `build_support/translate.h`, once per target: the published
53-platform Tier 1/2 table plus the six `check` targets
(`build.zig:163-170`), each read through the front end
`build_support/graph.zig:768 routeFor` gives it (Aro on a GNU libc target,
`zig cc -E -dD -fno-blocks` in front of it elsewhere). All 59 translate. Every
`pub extern fn|var|const` name that is not LuaJIT's own namespace was kept,
giving 502 names: the 280 before, plus 222 — the mingw secure-append block and
`corecrt_stdio_config.h`, the Darwin and BSD `<stdio.h>` spellings, the 45
`wasm-wasi-musl/wasi/api.h` entry points WASI's `<stdio.h>` reaches, and the
three stream objects.

The 149 names `src/*.h` declares are excluded, so no LuaJIT entry point is in
the list, and `provider_optional` and `provider_excluded` are unchanged. No
upstream byte is touched.

## 15 — An optimized translation declares externs the noise list did not have

**2026-10-04. `PENDING-VERIFICATION`.**

Entry 14 measured `libc_noise` with this build's own `translate-c`, once per
target. It covered all 59 targets and one *configuration*, and the
configuration is part of what `translate-c` reads. Zig's C front end adds
`-D_FORTIFY_SOURCE=2` to the `-Doptimize=ReleaseSafe` build and to none of
the other three; glibc defines `__USE_FORTIFY_LEVEL` only when
`_FORTIFY_SOURCE > 0` **and** `__OPTIMIZE__ > 0`
(`lib/libc/include/generic-glibc/features.h:454-473`), and behind that
`generic-glibc/stdio.h:956-959` includes `bits/stdio2-decl.h`, which declares
the fortified `<stdio.h>` family: a `__*_chk` implementation per fortified
function, a `__*_alias` redirect back onto the plain function, and a
`__*_chk_warn` sibling. `src/lauxlib.h:13` reaches `<stdio.h>`, so a
ReleaseSafe translation declares that family and a Debug one does not.

Observed, not inferred. Both loaded ReleaseSafe gates failed with
`MissingSymbol` against the source-built provider
`luajit-shared/lib/libluajit-5.1.so`, which exports exactly the 148 entry
points `src/lua.h`, `src/lauxlib.h`, `src/lualib.h` and the generated
`src/luajit.h` declare minus `lua_setlevel`, and no libc name at all. The
dispatch those two configurations generated required **163** names where every
passing configuration's required **148**, and the fifteen names the two differ
by are all of that family: `__dprintf_chk`, `__fgets_alias`, `__fgets_chk`,
`__fgets_chk_warn`, `__fprintf_chk`, `__fread_alias`, `__fread_chk`,
`__fread_chk_warn`, `__fread_unlocked_alias`, `__fread_unlocked_chk`,
`__fread_unlocked_chk_warn`, `__printf_chk`, `__vdprintf_chk`, `__vfprintf_chk`
and `__vprintf_chk`. The six other loaded gates and all eight native gates pass
against that same provider, so the provider was never the variable: what
changed was what this build demanded of it.

Twenty-three names from `bits/stdio2-decl.h` are added to `libc_noise`, which
now holds 525. Fifteen are the ones the fortified translation of this pin
reaches; eight more sit behind `__USE_GNU` or `__GLIBC_USE (DEPRECATED_GETS)`
and are listed because the list is a union across targets rather than this
one's. `runtime/graph.zig`'s comment cites each one's line in that header.

With those names de-routed the required table is the 148 header entry points in
every optimize mode, which is the invariant entry 14 was reaching for and did
not have. No upstream byte is touched, no required symbol is dropped, no alias
is invented and no check is suppressed.

**This entry records a source correction that has not been observed to fix
anything.** Both ReleaseSafe gates and the real consumer are unrun since the
edit, and no row of the gate table may be read as passing until they are.

## 16 — Three contract-review findings fully repaired, and the half of the fourth that is not

**2026-10-04. `PENDING-VERIFICATION`.**

From `local://foundation-contract-review-luajit.json`, which carried four
findings. Two were repaired in `build.zig`; the shared library's SONAME and the
two pkg-config assertions were repaired in the files that own them; and the
fourth is half repaired, with its remaining half named here so it is not lost.

**Repaired here.**

* **`lua_root` no longer defaults to a dependency's cache prefix.** It defaulted
  to `b.install_prefix` whenever that was absolute, and `createChildOnly` makes
  a `b.dependency` child's prefix `<cache>/i/<hash>`
  (`std/Build.zig:721-723`), so `LUA_ROOT`/`LUA_LJDIR` and the delivered CLI's
  `package.path` could name a directory the cache manager may discard — on the
  one route `consumer/` exists to prove. The default is now `install_root(b)`,
  which takes an absolute prefix that is **not** inside the build cache.
  `luajit.pc` needs none of that: it keeps `prefix=${pcfiledir}/../..`, and its
  `INSTALL_LMOD`/`INSTALL_CMOD` lines are left as the template's own `${prefix}`
  references, which is how `SED_PC` (`Makefile:86-90`) treats them, so nothing
  in the installed file is derived from a build machine's root.
  `--prefix` cannot be asked about the way `target_was_named` asks about
  `-Dtarget`: the build runner parses it itself
  (`lib/compiler/build_runner.zig:165-166`), so unlike `-Dtarget` it never
  reaches `b.user_input_options`, and the review's suggested
  `contains("prefix")` would have answered false every time. The location is
  what separates the two cases: a cache digest directory is the only prefix
  inside the cache.
* **`zig build consumer` forwards `-Dcpu`.** `-Dtarget=` carries architecture,
  OS and ABI and `Target.Query.zigTriple` says nothing about the CPU, so an ARM
  target crossed as `arm-linux-musleabi` lost which core it meant.
  `build_support/abi.zig:177-186` derives `LJ_ARCH_HASFPU` and the soft-float
  ABI from exactly those features and DynASM's FPU/HFABI choice follows from
  them, so the nested build configured a different VM than the one under test.
  It is forwarded when the caller named one, as
  `target.query.serializeCpuAlloc`.

**The rest, and where each one landed.**

* **The SONAME finding was in `build_support/graph.zig`, not `build.zig`, and
  its owner has repaired it there.** `addLibrary` passed no `.version`, so Zig
  emitted a single `libluajit-5.1.so` carrying no `SONAME` at all, and every
  dependent that linked it recorded the build machine's output path in its
  `DT_NEEDED`, where upstream installs
  `libluajit-5.1.so.2.1.1788856981` plus the `libluajit-5.1.so.2` and
  `libluajit-5.1.so` symlinks (`Makefile:57-59,139-140`). The review anchored it
  at `build.zig:681-686`, which is inside `addInstall` — header and `jit` module
  copies — and not a library creation; `build.zig` never calls `addLibrary`. It
  could not have been repaired from `build.zig` even in principle: `.version` is
  read where the library is created (`std/Build/Step/Compile.zig:491`) and has
  no setter afterwards, so installing the three names by hand would have left
  the ELF recording `DT_NEEDED libluajit-5.1.so`. It is now set: that file
  derives the version with `libraryVersion`, which parses `MMVERSION.RELVER`
  (`Makefile:26`) as a `std.SemanticVersion`, and passes it to `b.addLibrary`,
  which is what produces the real `lib<s>.so.<major>.<minor>.<patch>` name, the
  two symlinks where Zig creates them
  (`std/Build/Step/Compile.zig:490-507,1823-1832`) and the versioned SONAME
  itself (`std/Build/Step/Compile.zig:1492-1494`). The release digits are read
  from `.relver` at configure time rather than typed into the graph.
  **Unobserved:** nothing has been installed or run since that landed, so the
  three preserved CI assertions are still unproven.
* **The consumer route's other half is in `consumer/build.zig`.** `-Dlua-root`
  cannot be forwarded to the nested build: `consumer/build.zig` declares no such
  option and the build runner rejects an option no build script reads
  (`std/Build.zig:1644-1655`, reached from `build_runner.zig:487`), so passing it
  would fail the nested build rather than configure it. `--prefix` cannot be
  forwarded either, because `createChildOnly` replaces the dependency child's
  prefix whatever the nested build was told. Carrying the root into that child
  needs an option `consumer/build.zig` declares and forwards.
* **The pkg-config assertions were in `.github/workflows/verify.yml`**, which
  this entry does not touch; their owner has since repaired both of them. The
  review was right that `grep -q "^prefix=$PWD/out$"` cannot match the
  relocatable `prefix=${pcfiledir}/../..` this build's `addPkgConfig` writes on
  purpose, and `libname` was wrong in the same step for a different reason:
  `etc/luajit.pc` keeps the variable, so the line is `libname=luajit-${abiver}`
  and `pkg-config`, not the file, expands it. Both assertions now match an
  actually emitted `luajit.pc`, which carries exactly `prefix=${pcfiledir}/../..`,
  `libname=luajit-${abiver}`, `includedir=${prefix}/include/luajit-2.1` and
  `relver=1788856981`. The three SONAME assertions in the same job are the
  source correction in the bullet above, and like it they are unrun.

**What this costs:** nothing upstream and no gate result. Every repair in this
entry is source-confirmed and unobserved: no build has run since any of them
landed.

## 17 — The 53-cell matrix: four corrections, and the boundaries that stay upstream's

**2026-10-04. `PENDING-VERIFICATION`, written from an `OBSERVED-FAIL` run.**

From `cross-8/luajit/runs/20261004-151137-73716-18743`: 53 targets, `status=fail`,
44 cells whose build failed, 9 that built and were reported build-only, 0 passes.
Every correction below is source-confirmed and unobserved; no build has run since
that run. Three are in `build_support/graph.zig`; the fourth is one token in
`build_support/abi.zig`, with `build.zig`'s module documentation updated to match.

**Corrected.**

* **A 32-bit target now gets a 32-bit `buildvm`.** `src/host/buildvm.c:449-453`
  refuses to start unless `sizeof(void*)` equals `4*LJ_32+8*LJ_64`, and
  `LJ_32`/`LJ_64` are the *target's* (`lj_arch.h:671-677`), pinned on the
  generator's line by `applyTargetArchMacros` exactly as `src/Makefile:203`
  pins `$(TARGET_ARCH)` on `HOST_ACFLAGS`. Upstream's answer is its own
  `HOST_CC="gcc -m32"` (`src/Makefile:32`, worked examples at `:187-188`, one of
  them `CROSS=powerpc-linux-gnu-`). `generatorHostTarget` is that answer here:
  the build machine when its pointer width already matches, otherwise the same
  operating system with the same CPU family narrowed to 32 bits — musl on
  Linux, so the generator links statically and needs no 32-bit glibc and no
  dynamic loader — and a named panic for a build machine that has no 32-bit
  form, and for a 64-bit target on a 32-bit machine. No predefine is faked and
  the target's files are still generated by upstream's own `buildvm`: the
  correction is which machine the generator is compiled for, nothing else.
  `minilua` stays on the native host, because `src/host/minilua.c` includes C
  library headers only and `genversion.lua`/`dynasm.lua` read text and `-D`
  arguments.
  This is what 16 cells were blocked on: `x86-linux`, `x86-netbsd`,
  `x86-openbsd`, `x86-windows`, `arm-linux`, `arm-freebsd`, `arm-netbsd`,
  `arm-openbsd`, `thumb-linux`, `mips-linux`, `mipsel-linux`, `mips-netbsd`,
  `mipsel-netbsd`, and `powerpc-linux`, `powerpc-netbsd`, `powerpc-openbsd`,
  which reported `Error: pointer size mismatch in cross-build.` and, for the
  three PowerPC cells, additionally `lj_arch.h:369: "No support for PPC64"` —
  the second because `lj_arch.h:324-331` derives `LJ_ARCH_BITS` from the
  *host's* `_LP64`, which a 64-bit build machine defines. Both come from the
  same host-width leak and both close with a 32-bit generator.
* **The generator is told when the target is an Apple mobile or Mac Catalyst
  target.** `src/Makefile:373-376` puts `-DLUAJIT_OS=LUAJIT_OS_OSX
  -DLUAJIT_TARGET_IPHONE=1` on the *host* compile line when the target system is
  iOS, and the second define is load-bearing:
  `src/host/buildvm_lib.c:379-395` scans `lib_jit.c` with `#if LJ_HASJIT`
  resolved from *buildvm's own* `lj_arch.h`, while `lj_arch.h:130-133` reads the
  target's `TARGET_OS_IPHONE` when the library is compiled. Without the define
  a generator on a non-Apple host sees `LJ_HASJIT 1` and writes the `jit.util`
  entries into `lj_libdef.h` that the target's `lib_jit.c`, compiled with
  `LJ_HASJIT 0`, never defines — which is what both `*-maccatalyst` cells
  reported. It is pinned on the generator's line only, inside upstream's own
  `HOST_SYS != TARGET_SYS` guard (`src/Makefile:362`).
* **The preprocessed translation route completes `__int128_t`.** On
  `aarch64-netbsd` and `aarch64_be-netbsd` the translated module failed with
  `use of undeclared identifier '__int128_t'`: `-dD` keeps every `#define` in
  the file Aro parses, and NetBSD's `generic-netbsd/arm/cdefs.h:62-63` names
  `__int128_t` in a macro body without any header declaring the type. The
  route now `-include`s a generated header that typedefs the compiler's own
  builtin, guarded by the predefine the compiler itself emits
  (`__SIZEOF_INT128__`) and by `!defined(__int128_t)`. It declares no platform
  and restates no library declaration; this is the completion ERFA's
  translation aggregate already carries for its own NetBSD cells.
* **Mac Catalyst is grouped with Darwin in `build_support/abi.zig`.** Zig 0.16
  gives it its own `Os.Tag` (`std/Target.zig:42`) and its own `.macho` case
  (`:1049`), and the OS switch here listed
  `.macos, .ios, .tvos, .watchos, .visionos` without it, so `abi.select`
  answered `Os.other`, `vmOutput` (`abi.zig:318-324`) asked `buildvm` for
  `elfasm`, and the ELF directives of `src/host/buildvm_asm.c:195-232` reached a
  Mach-O assembler as a run of `unknown directive`s. `.maccatalyst` now sits in
  that group (`abi.zig:131-143`), which is what upstream says: Darwin takes
  `-DLUAJIT_OS=LUAJIT_OS_OSX` (`src/Makefile:370-372`), iOS takes the same with
  `-DLUAJIT_TARGET_IPHONE=1` (`:373-376`), and `lj_arch.h:81` reads
  `LUAJIT_OS_OSX` from `__MACH__ && __APPLE__`, which Catalyst satisfies. One
  token, and it also puts `LUAJIT_OS_OSX` back on the generator's line, restores
  `LUAJIT_UNWIND_EXTERNAL` on the library's (`src/Makefile:325`) and lets
  `addPkgConfig` apply `SED_PC`'s Darwin `-Wl,-E` removal
  (`src/Makefile:118`). No C source was touched.

**Not corrected, and why.**

* **mips64-linux / mips64el-linux.** Two diagnostics. `__clear_cache` is the
  real one: `src/lj_mcode.c:55-56` calls it under
  `#elif defined(__GNUC__) || defined(__clang__)`, and Clang does not declare
  it for these two targets, so the call is undeclared. `mips64-openbsd` and
  `mips64el-openbsd` fail on exactly that line and nothing else, which is the
  cleanest evidence that it is not this graph's doing. No C source was edited:
  it is upstream's own instruction-cache primitive, and the alternative would
  be a source change to a library file this wave does not authorise. The second
  diagnostic, `ignoring '-fno-PIC' option as it cannot be used with implicit
  usage of -mabicalls and the N64 ABI`, is **not** emitted by this graph: no
  `-fPIC` or `-fno-PIC` is on any command line this build writes, because
  `Module.pic` is left null and `appendZigProcessFlags` emits nothing for null
  (`std/Build/Module.zig:252`, `:554`, `addFlag`), and it appears on the
  `zig cc -E -target mips64-linux` line this graph writes for its preprocessed
  route — pcre2 writes the same line and its mips64 build still succeeded
  (`cross-8/pcre2/runs/20261004-152414-46202-30927/build-mips64-linux.log`), so
  the diagnostic does not decide whether a cell builds. Reported, not
  attributed, and not worked around: a `-fp ic`-style flag was not added,
  because nothing here shows which flag the compiler driver wants.
* **thumb-windows.** `src/host/buildvm_peobj.c:83-107` defines
  `PEOBJ_TEXT_FLAGS` for `LJ_TARGET_X86`, `LJ_TARGET_X64` and `LJ_TARGET_ARM64`
  only, and `emit_peobj` (`:203`) uses it unconditionally, so LuaJIT 2.1 has no
  PE object emitter for 32-bit ARM Windows. Upstream's own refusal, in a C
  source this wave does not edit.
* **Unsupported architectures were left refusing.** `armeb-linux`,
  `armeb-netbsd`, `hexagon-linux`, `loongarch64-linux`, `powerpc64-freebsd`,
  `powerpc64-linux`, `powerpc64le-freebsd`, `powerpc64le-linux`,
  `powerpc64-openbsd`, `riscv32-linux`, `riscv64-freebsd`, `riscv64-linux`,
  `riscv64-openbsd`, `s390x-linux`, `thumbeb-linux` and `wasm32-wasi` fail while
  the graph is being configured, because `build.zig:309-318` panics with
  upstream's own text and `lj_arch.h:69` or `lj_arch.h:369-370` before any step
  exists. That is the named refusal, and it is kept: `check` already observes it
  the other way, by running the target's own preprocessor over `src/lj_arch.h`
  and requiring that `#error` (`build.zig:625-667`). No cell was rewritten to
  look like coverage.

**What the driver runs.** One command per corrected shape, from the package
root with the pinned compiler:

```sh
# a 32-bit target end to end, generator included
zig build test -Dtarget=x86-linux -j8 --summary all
# the Apple mobile/Catalyst generator macro
zig build test -Dtarget=aarch64-maccatalyst -j8 --summary all
# the completed translation route
zig build test -Dtarget=aarch64-netbsd -j8 --summary all
```

`cross-test` needs no new flag for this. Its build runner
(`~/.local/lib/cross-test/run_policy.zig`) applies the executor it detected for
the cell's own target to every `Run` step whose executable matches that target's
architecture and OS, so an `x86-linux` cell's generator is covered by the same
prefix as its test binary. A cell whose target is MIPS or ARM keeps a generator
of the **build machine's own** family, narrowed to 32 bits — which is what
upstream's `HOST_CC="gcc -m32"` produces as well, since it is the host compiler
that gets `-m32` — so it runs wherever the machine runs its own 32-bit programs,
natively on x86_64 Linux, and needs `-fqemu` exactly where the test binary would.

## 18 — The installed pkg-config metadata now names the unwinder the archive needs

**2026-10-04. `OBSERVED-FAIL` for the defect; `PENDING-VERIFICATION` for the
fix.**

A C consumer built from a **static** install with `pkg-config --libs --static`
failed to link on the same eight undefined symbols entry 11 lists, every one of
them reported out of `libluajit-5.1.a`'s `lj_err.o`. The flags that did reach
the command line were `-lluajit-5.1 -Wl,-E -lm -ldl`, which is
`etc/luajit.pc:23-24` complete. Entry 11 made the graph link `gcc_s` and
recorded that the installed file still understated the link; this entry closes
that.

`addPkgConfig` now rewrites the `Libs.private` line to
`-Wl,-E -lm -ldl -lgcc_s` on the six targets `build_support/graph.zig` links it
for, and leaves upstream's three flags on every other target. `etc/luajit.pc`
is still read and rewritten rather than copied, so no upstream byte changed and
the entry 2 list still holds: what changed is the rendered file a consumer
reads. `FORK-NOTES.md` § 20 has the condition, the symptom and the bound.

**What this costs:** one flag, in one field, of one generated file, on six
targets, and nothing at all on any other target.

## 19 — Two doc comments that attributed a promise to the wrong mechanism

**2026-10-04. `SOURCE-CONFIRMED` for both; `PENDING-VERIFICATION` for anything
that would have to be run to confirm it.**

Neither finding changes a behaviour. Both were comments in which something true
about this build's behaviour was attached to a mechanism that does not produce
it, plus one that named a symbol this package does not have. Both were repaired
in place by the owner of those two files.

* `zig/root.zig`, the `State.openLibs` doc. It promised that `ffi` and
  `string.buffer` are reachable by `require` after `openLibs`, which holds, and
  attributed both to the preload table, whose one entry is `ffi`
  (`src/lib_init.c:32-37`). `string.buffer` is preregistered by `luaopen_string`
  itself (`src/lib_string.c:685-687`), so once registration is done that table
  holds both and the old wording could not describe it even as a snapshot. The
  promise is kept, each library's own guard is now cited, and the "exactly one
  entry" reading is gone. Reaching either is the facade's job, and the two are
  not alike: `State.openFfi` publishes `_G.ffi`, while `State.openStringBuffer`
  sets the field on the `string` global, because the C field setters do not
  split on a dot. Reported as finding 13; partially withdrawn after the
  consumer-facing half was re-read.
* `consumer/build.zig`'s trailing comment named `linkInstalledSibling`, which is
  no symbol anywhere in this package, and claimed the facade module carries
  `$ORIGIN/../lib`. The facade module is linked as `Loader.build_cache`, whose
  arm keeps the ordinary `Module.linkLibrary` call, so the build bakes the
  shared object's real directory into the program. `$ORIGIN/../lib` —
  `@loader_path/../lib` on Mach-O — is the `Loader.install_tree` arm, and it
  belongs to `bin/luajit` alone, which links the library through a module of
  its own.

No C source, header, test, data or licence file was touched, and nothing was
built, tested or run after either edit.

## 20 — The native self-check asked for two things this build never promised

**2026-10-04. `OBSERVED-FAIL` before; `OBSERVED-PASS` after — `zig build
native-test` against a brand-new prefix: 49 of 49 steps, 0 failures, 15 stopped
traces, `ffi.C.sqrt(16)` = 4, the dumped chunk reloaded and returned 42, and
`jit.vmdef`, `jit.bc` and `jit.dump` all loaded from the fresh install.**

`zig build native-test` against a brand-new prefix reported three failures, and
all three belonged to the script rather than to the delivery:

* `the JIT compiled at least one trace: 0 trace events`. The script subscribed
  with `jit.attach(cb, "trace")` and then counted callbacks whose first argument
  was `"trace"`. `"trace"` is the event being subscribed to and is never an
  argument; what a callback is handed is what the occurrence *is* — `"start"`,
  `"stop"` or `"abort"` (`lj_trace.c:474-488`, `:562-566`, `:626-646`) — which
  is how upstream's own `jit.dump` reads them (`src/jit/dump.lua:566-596`). The
  count was therefore zero whatever the JIT did, and the check could not have
  told a working engine from an interpreter-only one. It now counts stopped
  traces.
* `ffi table present: nil`, then `native_selfcheck.lua:112 attempt to index
  global ffi (nil)`. `ffi` is not a global and never was one: `luaL_openlibs`
  puts one entry into the registry's `_PRELOAD`, `{ LUA_FFILIBNAME,
  luaopen_ffi }` (`src/lib_init.c:32-37`), which is `package.preload`. The
  script now reaches it by `require` and guards the two FFI checks behind that,
  so a build without FFI reports one failure instead of dying on an index. Both
  semantic checks are kept: `cdef`, and a real call into libm through `ffi.C`.
* The module checks never ran, because the crash above came first. They read
  the install tree through `LUA_JPATH` — `LUA_LJDIR "/?.lua"` inside
  `LUA_PATH_DEFAULT` (`luaconf.h:56`, `:63`), with `LUA_LJDIR` compiled in as
  `<install root>/share/luajit-2.1` — and `native-test` depended on nothing that
  writes those files, so against a fresh prefix there was nothing to find. It
  now depends on the install step, as `addHeaderCheck` already does.

**What this costs:** `native-test` now also builds and stages the install tree
it reads. That is the price of a gate that cannot pass or fail by accident.

One configuration change lands beside it, and it is `devenv.nix` alone: every
task now changes into this SDK's own root (checked), fixes `-j8 --summary all`,
and keeps its cache under `$ZIG_LOCAL_CACHE_DIR/native`, with
`--prefix "$ZIG_LOCAL_CACHE_DIR/prefix"` on the install entries alone because
`test`, `smoke`, `check` and `consumer` wire to no install step. A caller-exported
`ZIG_LOCAL_CACHE_DIR` or `ZIG_GLOBAL_CACHE_DIR` is honoured as it stands, a task
fills only what is unset from `XDG_CACHE_HOME` and then `TMPDIR`, and it exits
1 rather than choose a location. Task names, steps and order are unchanged, and
`sdk:integrity` takes the root change and none of the rest.

## 21 — The nested consumer build now carries the configuration it resolves

**2026-10-04. `PENDING-VERIFICATION`. Nothing was built, run or compiled after
this edit; the defect is `SOURCE-CONFIRMED` from the pinned Zig 0.16.0 source
named inline, and only the driver's gate can move the status.**

`zig build consumer` runs `consumer/` as a genuinely nested `zig build`
(`build.zig:617-620`). Three things that this graph had already resolved were
not crossing into it, and one conditional was justified by the wrong mechanism.
No native source, header, test, data or licence file changed, no option was
added, and no caller's spelling changed.

**`-Dtarget` was serialized from the wrong side of the resolution.**
`build.zig:612` read `target.result.zigTriple`; it now reads
`target.query.zigTriple`, which is what `std.Build` itself uses to hand a
`ResolvedTarget` to a dependency (`std/Build.zig:451-462`).
`Target.Query.zigTriple` writes `native` for a query that names nothing
(`std/Target/Query.zig:421-423`), and a query that names nothing *is*
`b.graph.host` (`std/Build.zig:2704-2707`), so both graphs compile against the
linker this machine actually has. The resolved spelling could not say that: it
carries a host CPU feature range -- `x86_64-linux.6.12...6.12-gnu.2.42` here --
and a triple has no dynamic-linker field at all, so the nested build read an
explicitly named target, resolved it against the ABI defaults, and asked for
`/lib64/ld-linux-x86-64.so.2` where the host's linker is a Nix store path.
`Step.Run` refuses that, correctly, at
`std/Build/Step/Run.zig:1339-1343`. The same architecture, OS and libc version
are not a native selection. No `-Ddynamic-linker` was added: `b.dependency`
forwards no such argument, so forwarding it to the nested build alone would
give its consumer executable a linker its own library half never received.

**The global cache was not forwarded at all.** The helper already forwarded the
*local* cache as two tokens with a `/consumer` subdirectory, and left the global
one to the nested build's own resolution. `b.graph.global_cache_root.path` now
travels the same way (`build.zig:685-688`), with no subdirectory -- that cache
is keyed by content and shared by contract, so a suffix would name a directory
no other build here uses. It is two tokens because `--global-cache-dir [path]`
is (`build_runner.zig:1675`), and `std/Build/Step/Compile.zig:1478-1479` is the
compiler's own emit of the same pair. The field lives on `Graph`, not on
`Build` (`std/Build.zig:112-124`), so the path is `b.graph.global_cache_root`;
`Directory.path` is optional (`std/Build/Cache/Directory.zig:13`) but this runner
fills it unconditionally (`build_runner.zig:73-76`, `:89`), so the guard is the
type's and no fallback string is substituted.

**The job width and summary now travel.** `run.addArg("-j8")` and
`run.addArgs(&.{ "--summary", "all" })` (`build.zig:669-672`). Nothing can append
a `-j` to a `Run` step's command, so a nested build left to derive its own width
takes `cpu_count - 1` (`std/Io/Threaded.zig:1639`) and compiles at a width that
is neither the one asked for nor the same one on the next machine. `--summary`
is two tokens because that is the runner's spelling
(`build_runner.zig:262-265`). This is the width and summary
`AGENTS.md:157-158` requires of every entry point, applied to the one this
package owns.

**The conditional `-Dcpu` forwarding is unchanged, and its stated reason was
wrong.** `build.zig:651` still forwards the model only when the caller named
one, which is the correct predicate, but the comment beside it claimed
`standardTargetOptions` records both `target` and `cpu` into
`b.user_input_options` (`std/Build.zig:445-449` is `addUserInputOptionFromArg`'s
`Target.Query` arm on the `b.dependency` path, not this). The root map is filled
by the runner from the command line alone (`build_runner.zig:154`, `:157`), so
`contains("cpu")` is true for `-Dcpu=` and is *not* made true by a `-Dtarget`
that implies a model. Both graphs still agree when the branch does not fire:
with nothing named both resolve `b.graph.host`, and a bare `-Dtarget` leaves
both on the cross query's `baseline` model
(`std/Target/Query.zig:497-502`). The comment now says that, which is the
`PENDING-VERIFICATION` class this repository has already recorded once before
(entry 19).

**One earlier statement is superseded.** Entry 16's cost list said `-Dlua-root`
"cannot be forwarded to the nested build" because `consumer/build.zig` declared
no such option. It declares one now (`consumer/build.zig:76-82`) and the helper
forwards it (`build.zig:626`), so that limitation no longer describes this
package. `--prefix` travels as of entry 22, and it reaches the nested build's
own install step, not the dependency; entry 16's reason describes that hop.

Nothing else in the helper moved **by this entry**: the delivery, dispatch and
optimize modes, the executor switches, `--libc-runtimes`, local-cache and
`--`-behind-`b.args` handling are byte-for-byte as they were, and `run` stays
an unconditional `run` step, because a target with no executor is recorded as
build-only by the external matrix and must not look like a passing consumer.
The install root reached by this helper is entry 22's subject, not this one's.

## 22 — The nested consumer build installs where the caller asked

**2026-10-04. `SOURCE-CONFIRMED` for the source change;
`PENDING-VERIFICATION` for the gate. No build, run or compile followed this
edit, and no earlier entry's status moved.**

`runConsumer` hands the nested `zig build` the install prefix this invocation
resolved. It adds `--prefix` as two tokens when `b.install_prefix` differs from
`<build root>/zig-out`, and makes a relative value absolute against
`b.graph.cache.cwd` before the hop, because the run step's working directory is
`consumer/` and a relative prefix would resolve there rather than against this
build's root. Without it, `consumer/` resolved its own `consumer/zig-out` and
`b.installArtifact(exe)` wrote the consumer program into the source package
whatever `--prefix` the outer build was given. A caller who named no prefix
gets no argument, and the nested build resolves the same directory it resolved
before. `DESTDIR` needs no forwarding: the nested build inherits the
environment this one ran with.

**A prefix is still not a way to name the library's install root.** The library
reaches the consumer as `consumer`'s `b.dependency` child, and `createChildOnly`
replaces that child's prefix with a cache digest directory
(`std/Build.zig:721-723`) whatever the nested build was told. `-Dlua-root`
carries the resolved root past that, and `install_root` still refuses a prefix
inside the build cache. Entry 16's statement about `--prefix` is unchanged and
describes this second hop, not this argument.

**Nothing else in the helper moved.** The delivery, dispatch and optimize
modes, the conditional `-Dcpu`, the executor switches and `--libc-runtimes`,
`-j8 --summary all`, the local cache with its `consumer` subdirectory, the
inherited global cache, and the caller's arguments behind `--` stand as entry
21 recorded them. `run` stays an unconditional `run` step: forwarding an
executor does not prove that executor is available. No native source, header,
test, data or licence file changed, and no option was added.

## 23 — Two MIPS corrections in the architecture selector

**2026-10-04. `SOURCE-CONFIRMED` for the source change. The generator half is
`OBSERVED-PASS` on the receipt named below, the native half is
`OBSERVED-BOUNDARY`, and no earlier entry's status moved.**

`build_support/abi.zig` is this fork's own translation of `src/lj_arch.h` into
Zig terms, and two of its answers disagreed with the header they cite. No
upstream source changed: `select`, `targetArchMacros` and `dynasmDefines` keep
their signatures, and every non-MIPS target resolves exactly as before.

**`Selection.big_endian` carried the negation on both MIPS branches.** The
field's own comment says it means `LJ_ARCH_ENDIAN == LUAJIT_BE`
(`lj_arch.h:14-15`), but the `.mips`/`.mipsel` and `.mips64`/`.mips64el`
branches assigned `Cpu.Arch.endian() == .little`, the little-endian answer. Its
two consumers then contradicted each other. `targetArchMacros` emitted
`-D__MIPSEL__=1` when the field was true, which `lj_arch.h:401-405` reads at
`:419` as `LUAJIT_LE`, so the C side was right. `dynasmDefines` emitted
`ENDIAN_BE` for that same value. Both branches now assign `== .big`, and the
MIPSEL macro is emitted when `!s.big_endian`. The consequence was not one
branch: `src/vm_mips.dasc:204-220` takes `FRAME_PC`, `FRAME_FUNC`, `HI`, `LO`,
`OFS_RD`, `OFS_RA` and `OFS_OP` from `ENDIAN_LE`, and
`src/vm_mips64.dasc:210-222` takes `HI`, `LO` and the same three `OFS_*` values
for the 64-bit register and operand layout. The same define also gates the JIT
paths at `vm_mips.dasc:2982`, `:4813` and `vm_mips64.dasc:3092`, `:4998`. The
old value therefore mislaid the frame, the register halves and every operand
offset on both branches, for every MIPS target, and nothing failed to build.

**`MIPSR6` was never emitted.** `dynasmDefines` passed `VER`, and `VER` carries
`LJ_ARCH_VERSION` (`lj_arch.h:402-405`), but no `vm_*.dasc` in this tree reads
`VER`. The name DynASM does read is `MIPSR6`, and `vm_mips64.dasc` reads it 46
times, so all 46 of those guards took the non-R6 arm. `dynasmDefines` now
emits `MIPSR6` when `s.arch == .mips64` and `s.arch_version == 60`, and
`mipsIsR6` is what supplies the 60. The name is `.mips64` alone:
`lj_arch.h`'s `LJ_TARGET_MIPSR6` is in the 64-bit branch, and `vm_mips.dasc`
never reads it.

**A comment that overstated what it knew is corrected with them.** The closing
comment claimed that no `vm_*.dasc` reads `MIPSR6`, `SQRT` or `ROUND`.
`vm_ppc.dasc` reads `SQRT` once and `GPR64` 33 times, so only `MIPSR6` was a
missing emission. The other two PowerPC names stay unpassed for reasons the
comment now states: `_ARCH_PPCSQ` is a PowerPC-64 macro and `select` refuses
`.powerpc64` (`lj_arch.h:369-370`), no accepted target is a console build for
`GPR64`, and `ROUND` is read by nothing.

**Observed the same day, epoch `20261004T213021Z`.** The driver recorded
`-Dtarget=mips64-linux-muslabi64 -Dcpu=mips64r6 -Doptimize=ReleaseSafe` at
`/home/tmp2/gertullj/scratch/foundation-libs/review-contract-probes/evidence/after-20261004T213021Z/luajit-r6-mips64-compile.json`.
It exits 1 with exactly two diagnostics. The first is the N64 `-fno-PIC`
driver line, repeated once per translation unit. The second is
`call to undeclared function '__clear_cache'` at `src/lj_mcode.c:56:3`. The
native compile is therefore a boundary and is classified on its own: that is
an upstream primitive in an upstream C source, not a statement about this
entry. The generator half passes. The receipt decodes **5610** encoded words
from **1503** matched `.long` directive lines, with 0 skipped symbol operands
and 1077 non-instruction lines, and finds **63** R6 select forms against **0**
R2 ones, so `selected_mips_isa` is `r6`. The ISA is read out of the
instruction words -- `seleqz` 0x35 and `selnez` 0x37
(`dynasm/dasm_mips.lua:489,490`) against `movz` 0x0a and `movn` 0x0b
(`:625,626`) -- and not from branch counts, which the receipt records
separately and names as non-evidence. A compile is not a run, and no pinned
cross-test cell names this target.

## 24 — The nested consumer build ran, and its command line is on record

**2026-10-04. `OBSERVED-PASS` for the nine rows below. No earlier entry's
status moved, and no gate outside those rows changed.**

A driver ran `zig build consumer` for this SDK nine times in one epoch. The
receipt is
`/home/tmp2/gertullj/scratch/foundation-libs/nested-delivery-proof/evidence/20261004T220323250122Z-515d06adcbbf/index.json`,
which spans 22 SDKs; only its nine LuaJIT rows are used here. Every one is
`PASS`. Eight cover the two linkages and the two dispatch modes, each with a
default-target row and an explicit-target row, and the ninth is the refusal
case.

**Entries 21 and 22 are observed rather than argued.** Every captured nested
command line carried `-Dtarget`, `-Doptimize`, `-Dlinkage` and `-Druntime` with
the values the caller asked for, `-Dcpu=baseline` on the rows that named a
model, `-Dlua-root` set to the resolved root, `-j8 --summary all`,
`--cache-dir` with the local cache's `consumer` subdirectory,
`--global-cache-dir` with the caller's global cache, and `--prefix` with the
caller's external prefix. The prefix is recorded as present, propagated and
resolving outside this SDK tree on all nine rows. `-Dlua-root` and `--prefix`
held the same directory in these rows because the prefix was external; they
remain different values with different jobs, and `install_root` still refuses a
prefix inside the build cache.

**The provider arrives as argv and nothing else.** `LUAJIT_TEST_PROVIDER` was
excluded from every child environment, so a runtime-loaded row that reached its
provider reached it through the `-- --provider <path>` that
`consumer/src/main.zig` reads. The refusal row was handed neither an argument
nor a fallback: the program exited 1 and printed the refusal its own source
declares, which is the expected result for that case. Nothing here needed a
choice between the two routes, because there is no second route.

**Bounded.** Debug only, one host, `x86_64`, and the explicit-target rows name
`x86_64-linux-gnu`. No other optimize mode, no cross target and no provider
taken from a source tree were covered. Every other row of the gate table keeps
its previous status; the table is in `README.md` § 3.

## 25 — The consumer step asks whether this host can execute the target

**2026-10-05. `PENDING-VERIFICATION`: source-confirmed, never built or run. No
earlier entry's status moved, and no verification row changed.**

**Fixed.** `runConsumer` handed the nested `consumer/` build an unconditional
`run`, so `zig build consumer -Dtarget=<foreign triple>` asked a nested
`Step.Run` to spawn a binary that no enabled executor could reach. The step now
takes its sub-command from `hostCanExecute` (`build.zig:736`), which asks
`std.zig.system.getExternalExecutor` — the same question `Step.Run` asks about
the artifact it is about to spawn — with the build runner's own executor
switches in `allow_*` and the consumer's libc requirement in `link_libc`.
`.qemu` carries `Step.Run`'s second gate: a cross GNU-libc target with no
`--libc-runtimes` is one `Run` fails rather than skips, so it installs.

**What did not move.** The target query, the optimize mode, the linkage, the
dispatch mode, the conditional `-Dcpu`, `-Dlua-root`, the executor switches,
`--libc-runtimes`, `-j8 --summary all`, both cache arguments, the `--prefix`
rule and `b.args` behind `--` are byte-for-byte as entries 21 and 22 recorded
them, as is `run.has_side_effects`. The `-Dlinkage=static` default, the
`install_root` cache check and the conditional CPU forwarding rule are untouched,
and no option, default or query-normalisation rule was added.

**Bounded.** A target this host executes natively gets the same nested command
line as before, so entry 24's nine `OBSERVED-PASS` rows are untouched: their
explicit-target rows name `x86_64-linux-gnu`. Every other target builds and
installs `consumer/zig-out/bin/luajit-consumer`, or that path under a forwarded
`--prefix`. That is compile and link evidence, not a passing consumer, and no
cell of the external matrix may count it as one.

**No native change.** No C source, header, generated table, `jit/*.lua` module,
test, fixture, licence text or `UPSTREAM.sha256` entry changed. No LuaJIT
portability repair was made, no FFI or `dlsym` path was touched, and no
permanent test was added.

## 26 — The 53-cell matrix is recorded with its four boundaries kept apart

**2026-10-05. `OBSERVED-FAIL` for the matrix on the source epoch its receipt
records; the sixteen host-generator rows sit behind a correction that entry 27
records as landed and unverified. `SOURCE-CONFIRMED` for the reading of the
receipts. Nothing was built, compiled or run for this entry, and no earlier
entry's status moved.**

`README.md` § 3 gains "The source-bound 53-cell matrix and baseline,
2026-10-04/05" and "The delivered CLI's own self-check". The matrix is
`pass 0`, `build_only 11`, `build_fail 39`, runtime `fail 3`, run exit 1, from
`resume-8-evidence/20261004T221720228710Z-45046/luajit-53-target-8.json`;
the baseline `baseline-luajit-check` is exit 0 and `failed: false` from
`baselines-and-configs/20261005T014547Z-797a73f2/`; 8 of 8 native cells come
from `native-final-evidence/20261004T233628757747Z-69351/run.json` and 8 of 8
own-provider loaded cells from
`loaded-final-evidence/20261004T232823091897Z-23133/run.json`. **No cell of the
53 executed this SDK's suite and passed**, and `build_only` is stated as
coverage, never as a pass.

**The forty-two red cells are four things, and the four are not
interchangeable.** Sixteen are upstream's own architecture refusal — thirteen at
`abi.zig:313`'s `error.ArchitectureNotSupported`, which is `lj_arch.h:69`, and
three at `abi.zig:266`'s `error.Ppc64NotSupported`, which is `lj_arch.h:369-370`
— and none of those is fixable in this fork. Seven are compiler- or
upstream-bound: three fail compiling the generator on
`src/vm_arm64.dasc:1953:72: error: no member named 'J' in 'GG_State'` through
`src/lj_dispatch.h:122`, and four on
`src/lj_mcode.c:56:3: error: call to undeclared function '__clear_cache'`, the
primitive entry 23 already recorded. Three are runtime failures on the bare musl
triples `x86_64-linux`, `aarch64-linux` and `aarch64_be-linux`, 29 tests each,
with a **diagnosis this entry did not re-derive**: the receipts carry the
aggregate failure, not the `ffi.C`/`dlsym` symbol, so the cause is recorded as an
open item rather than a conclusion. The remaining sixteen are this fork's own
defect: `graph.zig:619` forces `.abi = .musl` on the 32-bit host generator, so
`buildvm` is built against `/lib/ld-musl-i386.so.1` and an x86-64 glibc host
refuses to run it.

**The sixteen host-generator rows are a fixed defect, not a platform limit.**
Entry 27 records the correction: the host generator on 32-bit Linux is linked as
a static executable rather than against a target libc. **That correction is not
part of this matrix and no row above is claimed to have moved**: a landed
correction is not a result, and those sixteen cells stand exactly as recorded
until a gate re-runs them.

**The native self-check, against a fresh prefix.** `zig build native-test`
reports 49 of 49 steps and 0 failures, with 15 stopped traces,
`ffi.C.sqrt(16)` = 4, the dumped chunk reloaded and returned 42, and
`jit.vmdef`, `jit.bc` and `jit.dump` loaded from the fresh install — which
carries the 19 `jit` modules, 18 byte-identical to `src/jit` plus the generated
`vmdef.lua`. An earlier install probe reported 47 of 47; entry 20's two added
module checks are the difference and that earlier count is history. Entry 20's
`OBSERVED-PASS` is unchanged and is not restated as new. GC64 stays a link-time
boundary: `src/lib_ffi.c:759-761` reports `"gc64"` in the FFI version string.

**Bound.** Every cell ran the same command shape —
`zig build test -Dtarget=<triple> -j8 --prefix … --summary all --color off
linkage or dispatch axis. The run predates the later build-graph edits,
including the host-generator correction above; its `source_unchanged: true`
speaks only to its own run and those edits are not claimed to be covered by it.
`README.md`'s `zig build test` row now says "as last run in this tree" and points
at the matrix, so it is no longer read as the current reading of that step. No C
source, header, generated table, `jit/*.lua` module, test, fixture, licence text
or `UPSTREAM.sha256` entry changed.

## 27 — The 32-bit host generator is linked statically instead of against a target libc

**2026-10-05. `SOURCE-CONFIRMED` for the source change. `PENDING-VERIFICATION`
for everything else: no build, test, smoke or matrix cell has been run against
this edit. No earlier entry's status moved, and entry 26's counts are unchanged.**

**The defect.** `build_support/graph.zig` built the host generator with `.abi =
.musl` forced onto the 32-bit Linux host. The generated tool was therefore
linked against `/lib/ld-musl-i386.so.1`, and an x86-64 glibc host refused to
spawn it — `Step.Run`'s own check, reported as *the host system is unable to
execute binaries from the target because the host dynamic linker is
`/lib64/ld-linux-x86-64.so.2`, while the target dynamic linker is
`/lib/ld-musl-i386.so.1`*. Sixteen of the 53 cells in entry 26 stop there, once
per `buildvm -m {elfasm,machasm,peobj,bcdef,ffdef,libdef,recdef,folddef}`
invocation, so one cause produced sixteen identical red rows.

**Why a static host executable is the right answer.** The generator is a *host*
tool: it reads this tree's `.dasc` and `.h` sources and writes generated
headers, and the bytes it writes must not depend on the libc of the target being
cross-compiled. Declaring a host musl32 target and then linking it dynamically
introduced a second, worse disagreement: the target query *declared* a static
musl32 host while the produced binary was *actually* a dynamic object, so the
absence was reported as an `ENOENT` on a file the build believed it had written.
Linking the 32-bit host generator as a static executable removes the target
libc from the question entirely and makes what is built match what is declared.

**Bounded.** The change is confined to the host generator's linkage inside
`build_support/graph.zig`. No C source, header, generated table, `jit/*.lua`
module, test, fixture, licence text or `UPSTREAM.sha256` entry changed, no
option or default was added or removed, and no architecture selection moved:
the sixteen upstream refusals, the seven compiler- and upstream-bound rows and
the three musl `ffi.C`/`dlsym` runtime rows in entry 26 are untouched by this
and are not claimed to have moved either.

**What has to happen before any of the sixteen reads as fixed.** In order: a
three-cell host probe over representative 32-bit targets, then a full 53-cell
replay against this source. Until both have printed, entry 26's `pass 0`,
`build_only 11`, `build_fail 39` and runtime `fail 3` remain the record, and
they are explicitly the `20261004T221720228710Z-45046` **pre-host-fix** cohort.
A landed correction is not a result.

## See also

* [`FORK-NOTES.md`](FORK-NOTES.md) — why each of the above was decided, and
  what it cost
* [`UPSTREAM.md`](UPSTREAM.md) — the pin, the closure, the ABI facts
* [`README.zig.md`](README.zig.md) — the Zig interface and the gate table