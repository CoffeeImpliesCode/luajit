# UPSTREAM.md — what this fork is a fork of

## Upstream

| | |
|---|---|
| Project | LuaJIT — a Just-In-Time compiler for Lua |
| Canonical site | <https://luajit.org/> |
| Repository | <https://github.com/LuaJIT/LuaJIT> (official project mirror) |
| Pin | `c6ffc141a8762b41703f9287d63d93622a13dd8f` |
| Series | production `v2.1`, rolling release (no `v2.1.x` tag exists) |
| Acquired as | `https://codeload.github.com/LuaJIT/LuaJIT/tar.gz/c6ffc141a8762b41703f9287d63d93622a13dd8f` |
| Archive SHA-256 | `6e5fec07750add912e7c3eae0c194d24cd6d023714e1f04a0298a5b4819e4457` |
| Import | whole snapshot, 233 files, no patch applied |

The archive digest is the value the workspace delivery record
`local://foundation-contract-new-source-pins.json` carries for this project.
This repository does not fetch anything: the pinned tree is here.

There is no release tarball to fall back on. LuaJIT's rolling scheme means
every commit after the last `v2.1.0-beta3` tag has a different version
string, so a build from a *different* snapshot is a different binary, not a
rebuild of this one. `README.zig.md` explains the identity symbol that makes
that detectable at link time.

## The version string is generated, not written

This is the one part of the tree a reader cannot get from a source file, so
it is derived here in full.

1. `.relver` contains `1788856981`. It is an upstream file — `Makefile` and
   `src/Makefile` both read it, and `.gitattributes` marks it
   `export-subst` — and it holds the **Unix commit timestamp of the pinned
   commit**, `2026-09-08T08:43:01Z`.
2. `Makefile:16-26` computes `VERSION = $(MAJVER).$(MINVER).$(RELVER)` =
   `2.1.1788856981`.
3. `src/Makefile:495` chooses where `RELVER` comes from:
   `[ -e ../.git ] && git show -s --format=%ct > luajit_relver.txt || cat ../.relver > luajit_relver.txt`.
   With a Git checkout it is the real commit timestamp; in a source tarball,
   such as this SDK's package, there is no `.git`, so the committed `.relver`
   supplies the same value.
4. `src/Makefile:670-673` runs `src/host/genversion.lua`, which
   `gsub`s every literal `ROLLING` in `src/luajit_rolling.h` with that
   number and writes `src/luajit.h`.

So the generated `src/luajit.h` declares:

| Macro | Generated value |
|---|---|
| `LUAJIT_VERSION` | `"LuaJIT 2.1.1788856981"` |
| `LUAJIT_VERSION_NUM` | `20199` (upstream marks this deprecated; it is not the relver) |
| `LUAJIT_VERSION_SYM` | `luaJIT_version_2_1_1788856981` |
| `LUAJIT_COPYRIGHT` | `"Copyright (C) 2005-2026 Mike Pall"` |
| `LUAJIT_URL` | `"https://luajit.org/"` |

`LUAJIT_VERSION_SYM` becomes a real exported function
(`luajit_rolling.h:76-77`, *"Enforce (dynamic) linker error for version
mismatches. Call from main."*). That is the ABI identity symbol: a program
built against a different rolling snapshot fails to link against this
library instead of silently misbehaving. A provider claiming to be this
LuaJIT must export exactly `luaJIT_version_2_1_1788856981`.

`build.zig.zon`'s `.version` is `2.1.1788856981`, the same string. It is not
a hard-coded guess: it is the version the pinned snapshot generates, and the
build graph reads `.relver` to reproduce it.

`src/host/README:3` states that the host tools *"should NOT be installed"*.
This SDK installs none of them; it runs them on the build host.

## What this fork is

A Zig package that compiles upstream's own C from `src/` in this repository
and publishes a Zig facade over the six public headers upstream installs.
`build.zig` is the whole build: no `make`, no `src/Makefile`, no CMake, no
`host/buildvm` output hand-written, and no build-time download.

### The compiled closure

`src/Makefile:512-532` is upstream's own object list and is the
authoritative statement of what the core is. It builds
`$(LJVMCORE_O) = $(LJVM_O) $(LJCORE_O)`:

| Upstream variable | Count | What it is |
|---|---|---|
| `$(LJVM_O)` | 1 | `lj_vm.o`, **assembled**, not compiled — see below |
| `$(LJCORE_O)` | 69 | the C translation units: 55 `lj_*.c`, `lib_aux.c`, the 12 `$(LJLIB_O)` units and `lib_init.c` |
| `$(LJLIB_O)` | 12 | the standard libraries, `src/Makefile:512-514` |
| `$(BUILDVM_O)` | 5 | build-host tools, never installed |
| `$(MINILUA_O)` | 1 | build-host tool, never installed |
| `$(LUAJIT_O)` | 1 | the `luajit` front end |

The **library** is `$(LJVMCORE_O)`: **69 C translation units and one assembled
object, 70 objects in all.** `src/Makefile.dep` is the same closure in
dependency form and names 77 objects, the extra seven being the host tools,
the front end and `ljamalg.o` — upstream's amalgamation entry point
(`src/Makefile:636-637`), which is deliberately not built here because it
`#include`s the same sources and would define every symbol twice.

The 55 core `lj_*.c` units are the API (`lj_api.c`), the collector
(`lj_gc.c`), the allocator (`lj_alloc.c`), parser and lexer (`lj_parse.c`,
`lj_lex.c`), the IR and its optimisers (`lj_ir.c`, `lj_opt_*.c`), the back
ends (`lj_asm.c` with `lj_emit_*.h`, `lj_asm_*.h`, `lj_target_*.h`, and the
snapshotter `lj_snap.c`), the trace recorder (`lj_record.c`,
`lj_ffrecord.c`), the FFI machinery (`lj_ccall.c`, `lj_ccallback.c`,
`lj_cdata.c`, `lj_cparse.c`, `lj_clib.c`, `lj_cconv.c`, `lj_carith.c`,
`lj_crecord.c`), and the string/number/table/debug machinery around them.

### The seventieth object is generated, and so are seven headers

`lj_vm.o` is not a C file. `src/Makefile:507-510` builds `lj_vm.S` with
`$(BUILDVM_X) -m $(LJVM_MODE)` and assembles it; `$(LJVM_MODE)` is `elfasm`
on ELF, `machasm` on Mach-O, and `$(LJVM_O)` becomes an object file rather
than assembly on Windows (`src/Makefile:522-525`). The `.dasc` input is
`vm_$(DASM_ARCH).dasc` (`src/Makefile:489`), one of `vm_x86.dasc`,
`vm_x64.dasc`, `vm_arm.dasc`, `vm_arm64.dasc`, `vm_mips.dasc`,
`vm_mips64.dasc`, `vm_ppc.dasc`.

The whole generator chain, in the order `src/Makefile` imposes:

| Step | Tool | Input | Output |
|---|---|---|---|
| 1 | host C compile (`src/Makefile:499-502`) | `buildvm.c`, `buildvm_asm.c`, `buildvm_peobj.c`, `buildvm_lib.c`, `buildvm_fold.c`, and the **checked-in** `buildvm_libbc.h` | `host/buildvm` |
| 2 | host C compile (`src/Makefile:392,666-668`) | the **checked-in** `host/minilua.c` | `host/minilua` |
| 3 | `host/minilua` + `../dynasm/dynasm.lua` (`src/Makefile:404,675-677`) | the target `.dasc` | `host/buildvm_arch.h` |
| 4 | `host/buildvm -m bcdef / ffdef / libdef / recdef` (`src/Makefile:689-703`) | `$(LJLIB_C)` | `lj_bcdef.h`, `lj_ffdef.h`, `lj_libdef.h`, `lj_recdef.h` |
| 5 | `host/buildvm -m folddef` (`src/Makefile:709-711`) | `lj_opt_fold.c` | `lj_folddef.h` |
| 6 | `host/buildvm -m vmdef` (`src/Makefile:705-707`) | `$(LJLIB_C)` | `jit/vmdef.lua` |
| 7 | `host/minilua host/genversion.lua` (`src/Makefile:670-673`) | `luajit_rolling.h` + `luajit_relver.txt` | `src/luajit.h` |
| 8 | `host/buildvm -m $(LJVM_MODE)` (`src/Makefile:685-687`) | the target `.dasc` | `src/lj_vm.S`, then `lj_vm.o` |

Two of those inputs are **checked in, not generated**, and that is
deliberate. `src/host/minilua.c` is upstream's already-minified Lua 5.1.5
amalgamation: `src/host/genminilua.lua` would have to regenerate it from a
Lua 5.1.5 source tree, which this repository does not carry and this SDK does
not fetch. `src/host/buildvm_libbc.h` is the output of `src/Makefile:642-644`'s
`libbc` target, which needs a fully built `luajit` and the same absent source
tree; upstream ships the result, and so does this repository. Both are in
`UPSTREAM.sha256`.

Because `host/minilua.c` is checked in, there is no bootstrap puzzle: the
host tools are ordinary C, and the first `host/minilua` is compiled rather
than produced. `src/Makefile:398-400` defaults `$(HOST_LUA)` to
`host/minilua` for exactly that reason.

The generators are **host tools**. `src/host/README:2` requires it: *"For
cross-compilation, they must be executed on the host, not on the target."*
The build graph therefore compiles them for the build host and runs them to
produce inputs for the target — it never copies host platform macros onto a
cross target.

Every generated input is produced **for the target being built**. `lj_arch.h`
selects `LJ_TARGET_GC64`, the back end, the jump range and the page size from
target macros, and `host/buildvm_arch.h` is what DynASM generated from them;
copying a host-configured one onto a cross target would produce the wrong VM.

### The four ABI facts a consumer has to know

Read out of the source, not assumed:

* **Language ABI.** `src/lua.h:19-21` declares `LUA_VERSION "Lua 5.1"`,
  `LUA_RELEASE "Lua 5.1.4"`, `LUA_VERSION_NUM 501`. LuaJIT is a Lua **5.1**
  implementation. It is not ABI-compatible with the separate Lua 5.5 SDK in
  this workspace and must never be substituted for it: a 5.5 program linked
  against this library is a different program.
* **Numeric ABI.** `src/luaconf.h:118-119` fixes `LUA_NUMBER` to `double`,
  and `luaconf.h:106` fixes `LUA_INTEGER` to `ptrdiff_t`. On a 32-bit target
  `lua_Integer` is therefore 32 bits wide; on a 64-bit target it is 64.
  `luaconf.h:105` says plainly that changing these *breaks the Lua 5.1 ABI*.
  `LUA_IDSIZE` is 60 (`luaconf.h:107`) and `LUAI_MAXSTACK` is 65500
  (`luaconf.h:91`).
* **GC64.** `LJ_TARGET_GC64` is set by the architecture block, and the three
  64-bit architectures set it unconditionally: arm64 (`lj_arch.h:303`) and
  mips64 (`lj_arch.h:459`) always, and x64 by default
  (`lj_arch.h:216-220`, unless `LUAJIT_DISABLE_GC64` is defined, which
  `lj_arch.h:218-219` rejects outright on macOS). The 32-bit architectures —
  x86, arm, ppc, mips32 — run the non-GC64 VM. GC64 changes object frame
  sizes (`lj_ir.h:311`, `lj_frame.h:141-160`) and the collector's addressable
  range (`lj_alloc.c:101-108`) without changing a single C API type, so it is a
  *link-time* boundary rather than a source-level one: an x64 library built
  with `-DLUAJIT_DISABLE_GC64` exports the same symbols and must not be mixed
  with one built without it. `src/lib_ffi.c:759-761` reports `"gc64"` in the
  FFI version string, so a provider can be asked which mode it is in.
  Consoles and Xbox One define it too (`lj_arch.h:165-169`).
* **Export visibility.** `src/luaconf.h:135-136` makes `LUA_API`
  `extern __attribute__((visibility("default")))` on ELF and Mach-O, and
  `luaconf.h:129-133` distinguishes `__declspec(dllexport)` from
  `__declspec(dllimport)` behind `LUA_BUILD_AS_DLL` on Windows. A shared
  build must keep those macros as upstream writes them; a version script or
  `-fvisibility=hidden` applied *before* `LUA_API` is defined would work,
  one applied after it would export nothing.

### Link dependencies

`etc/luajit.pc:24` gives upstream's own answer:
`Libs.private: -Wl,-E -lm -ldl`. `-lm` is libm; `-ldl` is `dlopen`, which the
FFI library needs to load C declarations at run time; `-Wl,-E` exports the
dynamic symbol table, which the FFI's callback and JIT machinery relies on.
Upstream's `Makefile:118` drops `-Wl,-E` on Darwin and switches the shared
library names to `.dylib`, so the metadata is platform-specific and is
generated per platform rather than copied.

**There is a fourth dependency, and upstream never writes it down.**
`etc/luajit.pc` does not mention it because a GCC driver supplies it for free.
`src/Makefile:325` puts `-DLUAJIT_UNWIND_EXTERNAL` on Darwin, and `:343` puts it
on every toolchain whose objects always carry unwind tables — the ELF case for
every toolchain this SDK uses. That macro selects `LJ_UNWIND_EXT`
(`src/lj_arch.h:717-721`), and under it `src/lj_err.c` declares **eight** APIs it
does not define:

| Name | Where upstream declares it | What it is |
|---|---|---|
| `_Unwind_GetCFA` | `src/lj_err.c:424` | canonical frame address of the frame being unwound |
| `_Unwind_SetGR` | `src/lj_err.c:425` | writes the register the EH return code lands in |
| `_Unwind_GetIP` | `src/lj_err.c:426` | the instruction pointer to resume at |
| `_Unwind_SetIP` | `src/lj_err.c:427` | where the unwinder continues |
| `_Unwind_DeleteException` | `src/lj_err.c:428` | ends an `_Unwind_Exception`'s lifetime |
| `_Unwind_RaiseException` | `src/lj_err.c:429` | enters the unwinder |
| `__register_frame` | `src/lj_err.c:601` | registers the JIT error trampoline's FDE |
| `__deregister_frame` | `src/lj_err.c:602` | and withdraws it |

Those eight are the **Itanium C++ ABI unwinder ABI**, and libgcc supplies them.
A GCC or Clang driver adds that library without being asked, which is why
upstream's `Makefile` never names it and `luajit.pc` never lists it. A build
graph that compiles C objects *without* that driver has to say so itself. That
is a property of the toolchain rather than of this fork, and it is why
`build_support/graph.zig` links `gcc_s` explicitly on the ELF Unix targets —
`.linux`, `.hurd`, `.freebsd`, `.netbsd`, `.openbsd`, `.dragonfly`.

`_Unwind_Find_FDE` (`src/lj_err.c:501`) is a ninth such name in that file and is
**not** among the eight: it sits inside
`#if LJ_UNWIND_EXT && defined(LUA_USE_ASSERT)`, and neither `LUA_USE_ASSERT` nor
`LUA_USE_APICHECK` is defined in this build, so nothing references it.

There is no vendored `libffi` and no vendored copy of any other library. The
FFI is LuaJIT's own.

## What is upstream's and is shipped unmodified

Everything with a record in `UPSTREAM.sha256`: all 232 of them. That is the
snapshot's `src/` (194 files), `dynasm/` (14), `doc/` (16), `etc/` (2), and
the seven root files `.gitattributes`, `.gitignore`, `.relver`, `COPYRIGHT`,
`Makefile`, `README`, `README.upstream.md`. `.gitignore` is upstream's and
is kept verbatim at the head of the working-tree file, but the fork appends
its own Zig block below it, so the working copy is no longer byte-identical
and has no record; upstream's own bytes are quoted in the record's header.

Two files are upstream's **but are not shipped as part of the installed
package**, and are recorded here for that reason:

* `Makefile` and `src/Makefile`. The SDK does not run `make`; it compiles the
  same source list with Zig. They stay because `src/Makefile` is the
  specification for the generated inputs and `src/Makefile.dep` is the
  specification for the closure, and both are read to write `build.zig`.
* `src/Makefile.dep` is upstream's dependency list, kept verbatim for the
  same reason.

`src/host/README:3` marks the whole `src/host/` directory "should NOT be
installed", and this SDK honours that: none of the thirteen host files is
installed. They are in the source package because the build runs them.

## Integrity

`UPSTREAM.sha256` holds **232** records, one `<hex>  <path>` line each in
`sha256sum` format. Check it with:

```sh
sha256sum -c UPSTREAM.sha256
```

It covers the pinned source, upstream's licence text, upstream's README and
the documentation. It deliberately excludes generated files (they do not
exist until a build runs) and this fork's own files. Both exclusions are
enumerated in the record's own header, together with the digest of upstream's
`.gitignore`, which this fork extends rather than replaces.

The only file in this repository that is upstream's bytes at a fork-specific
path is `README.upstream.md`: upstream's `README`, moved aside so this fork
could put its own `README.md` in its place. Both files are in the record and
carry the same digest.

## Synchronising with a new upstream commit

1. `git fetch upstream`, check out the new commit, and read the new `.relver`.
2. That number, not a version you type, is the release version: run it
   through steps 1–4 above to get `LUAJIT_VERSION` and `LUAJIT_VERSION_SYM`.
3. Re-run `sha256sum -c UPSTREAM.sha256` against the pristine checkout to see
   exactly which upstream files moved before anything is recompiled.
4. Update `build.zig.zon`'s `.version`, the archive digest in
   `UPSTREAM.sha256`'s header, this file and `CHANGELOG.md` in the same
   change. A rolling-release bump has no tag to point at, so the archive
   digest and `.relver` *are* the pin.

## Verification status

The gate table lives in [`README.md`](README.md#3-build-run-and-test-matrix),
with the Zig-surface subset in
[`README.zig.md`](README.zig.md#verification-status). **Nothing in this file is a
gate result:** everything above is read out of the pinned source or derived from
`.relver`.

What has been observed is narrow, and it failed. The native closure compiles and
links once the external unwinder above is named, and `zig build test` in Debug
last reported **29 tests: 5 pass, 2 fail, 22 crashed**. Every other row in those
tables is still `PENDING-VERIFICATION`.

## See also

* [`NOTICE.md`](NOTICE.md) — attribution and the per-file licence audit
* [`FORK-LICENSE.md`](FORK-LICENSE.md) — the grant over this fork's own files
* [`README.upstream.md`](README.upstream.md) — upstream's README, byte-identical
* [`UPSTREAM.sha256`](UPSTREAM.sha256) — the 232 digests and their exclusions