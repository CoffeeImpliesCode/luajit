# FORK-NOTES

Decisions, why each was made, and what each cost. Numbered sections; the
changes themselves are in [`CHANGELOG.md`](CHANGELOG.md).

The workspace rule is that a lesson is only a rule if it names its boundary.
Every section below ends with **Bound**. A claim about what the source says is
`SOURCE-CONFIRMED` and carries its file and line; a claim about what a command
will do is `HYPOTHESIS` or `CONSTRAINT`. Where a command has actually been run,
the run is named and dated in
[`README.md`](README.md#3-build-run-and-test-matrix) and is not restated here as
a conclusion — this file records why something was done, not whether it worked.

---

## 1. `src/luajit.h` does not exist in the repository, and must not be created by hand

**Condition.** Any translation step that adds `src/` to its include path and
compiles a file that includes `luajit.h`.

**Symptom.** `src/luajit.h` is absent, because `src/.gitignore:2` lists it.
`src/luajit_rolling.h` is present and ends with
`#error "DO NOT USE luajit_rolling.h -- only include build-generated luajit.h"`
(`luajit_rolling.h:79`), so including it directly fails loudly rather than
silently. That `#error` is upstream protecting exactly this mistake.

**Fix.** Run upstream's own generator. `src/Makefile:670-673` is the
specification: `$(GIT_RELVER)` then `host/genversion.lua`, which
`gsub`s every literal `ROLLING` in `luajit_rolling.h` with the relver and
writes `luajit.h`. The build graph does this for the target being built and
puts the result on the include path of both the compile line and the
translation line.

**Why it matters beyond the error message.** The generated header also
declares `LUAJIT_VERSION_SYM`, the identity symbol. A hand-written
`luajit.h` would compile and would silently drop the one link-time check that
distinguishes this rolling build from any other.

**Bound.** All targets. There is no platform on which a checked-in
`src/luajit.h` would be correct, because its content depends on the commit
being built.

## 2. The version is a commit timestamp, so a typed version is a false pin

**Condition.** `build.zig.zon`'s `.version`, `package.nix`'s `version`,
anything printed by `smoke.zig`, and every `luajit.pc` this package installs.

**Symptom.** LuaJIT has no `v2.1.x` tags. `Makefile:16-26` builds the version
as `$(MAJVER).$(MINVER).$(RELVER)`, and `src/Makefile:495` sources `RELVER`
from `git show -s --format=%ct` or, with no `.git` directory, from the
committed `.relver`. A version typed by hand cannot be checked against
anything, and would drift from the generated `luajit.h` the moment the pin
moved.

**Fix.** `.relver` is the single source: it holds `1788856981`, the pinned
commit's Unix timestamp, which is `2026-09-08T08:43:01Z`. Everything downstream
— `build.zig.zon`'s `.version`, the install prefix names, `package.nix`'s
`version`, the soname, the `luajit.pc` `Version:` line — derives from it. The
`installCheckPhase` reads the version back out of the installed
`luajit.pc` and compares it, so a mismatch fails the build instead of
shipping.

**What a reader must not conclude.** `LUAJIT_VERSION_NUM` is `20199` and is
marked *Deprecated* in `luajit_rolling.h:34`. It is **not** the release
version and must never be used as one.

**Bound.** All targets and both delivery variants; the string is generated
once per build and used everywhere.

## 3. The generators run on the host, and two of their inputs are checked in

**Condition.** Any cross build, and any build on a machine with no Lua
interpreter installed.

**Symptom.** `genversion.lua` and `dynasm.lua` are Lua programs, so something
has to run them. Running them needs a Lua interpreter, and the one LuaJIT
provides (`host/minilua`) is itself a C program that has to exist first.
Getting this wrong on a cross build does not fail loudly — it produces a
target library built from a *host*-configured VM.

**Fix.** Upstream's chain, in `src/Makefile`'s order, with the two checked-in
inputs called out because they are the trap:

1. `host/buildvm` — compiled from C (`buildvm.c` and the four `buildvm_*.c`)
   together with the **checked-in** `host/buildvm_libbc.h`. No Lua needed.
2. `host/minilua` — compiled from the **checked-in** `host/minilua.c`. This
   is upstream's already-minified Lua 5.1.5 amalgamation.
3. `host/minilua ../dynasm/dynasm.lua -o host/buildvm_arch.h vm_<arch>.dasc`
   (`src/Makefile:404,675-677`) — target macros in, back end out.
4. `host/buildvm -m bcdef|ffdef|libdef|recdef|folddef` — the five `lj_*def.h`
   headers.
5. `host/buildvm -m vmdef -o jit/vmdef.lua` — the VM definition module.
6. `host/minilua host/genversion.lua` — `src/luajit.h`.
7. `host/buildvm -m elfasm|machasm|peobj -o lj_vm.S` — the VM, assembled for
   the target.

**The trap:** steps 2 and 1 look like they should regenerate
`src/host/minilua.c` and `src/host/buildvm_libbc.h`. They must not.
`src/host/genminilua.lua` needs a Lua 5.1.5 source tree that this repository
does not carry and this SDK does not fetch, and `src/Makefile:642-644`'s
`libbc` target needs a fully built `luajit` plus the same absent tree.
Upstream ships both results; so does this repository; both have digests.
Reading `src/host/README` and the `.gitignore` files is the way to see which
inputs are generated and which are shipped — `src/.gitignore` lists exactly
the generated ones.

`src/host/README:2` requires every step to execute **on the host**, not the
target. That is the difference between compiling the generator once and
compiling it twice.

**Bound.** Cross builds specifically: on a native build the host tool and the
target happen to be the same machine, which hides a wrong ordering until the
first cross build.

## 4. GC64 is a per-architecture choice, and it is a link-time boundary

**Condition.** Any decision about `LUAJIT_DISABLE_GC64`, or any assumption
that two LuaJIT builds of the same source are interchangeable.

**Symptom.** `LJ_TARGET_GC64` is set by the *architecture* block, not by one
global default. arm64 (`lj_arch.h:303`) and mips64 (`lj_arch.h:459`) set it
unconditionally; x64 sets it unless `LUAJIT_DISABLE_GC64` is defined
(`lj_arch.h:216-220`), and makes that macro a hard `#error` on macOS; the
32-bit architectures — x86, arm, ppc, mips32 — run the non-GC64 VM. GC64
changes object sizes (`lj_ir.h:311`, `lj_frame.h:141-160`) and the
collector's addressable range (`lj_alloc.c:101-108`) without changing a
single C API type. So an x64 library built with `-DLUAJIT_DISABLE_GC64` and
one built without it export the *same* symbols, link against the same
headers, and are not interchangeable. The failure is not a link error; it is
undefined behaviour at run time.

**Fix.** Do not build the non-GC64 x64 configuration in this SDK, and say so.
`src/lib_ffi.c:759-761` reports `"gc64"` in the FFI version string, so a
provider can be asked which mode it is in; `README.zig.md` records that.

**Bound.** Every target, but only x64 is a *choice* — everywhere else it is
fixed by the architecture, and on macOS it cannot be turned off at all.

## 5. Export visibility is the whole shared-library mechanism

**Condition.** Building the `shared` variant, especially with any global
`-fvisibility=hidden` or a version script.

**Symptom.** `src/luaconf.h:135-136` gives `LUA_API` the definition
`extern __attribute__((visibility("default")))` on ELF and Mach-O.
`luaconf.h:129-133` splits `__declspec(dllexport)` from
`__declspec(dllimport)` behind `LUA_BUILD_AS_DLL`. Every public entry point
depends on that macro. Hide symbols before the macro expands and nothing is
exported; there is no error, only an empty library.

**Fix.** Compile with upstream's macros exactly as written. If a version
script is used, it must list the exported names rather than assume they are
already visible. `package.nix`'s `installCheckPhase` fails on a missing
library artifact rather than shipping an empty one, but the symbol list is the
build graph's to get right and this note does not restate it.

**Bound.** All platforms; the ELF, Mach-O and Windows paths are three
different mechanisms.

## 6. The pkg-config name is `luajit-5.1`, not `luajit`

**Condition.** Any `.pc` this SDK installs, and any consumer that links by
name.

**Symptom.** `etc/luajit.pc:12` sets `libname=luajit-${abiver}` with
`abiver=5.1` (`etc/luajit.pc:6`), and `Makefile:56` installs
`libluajit-5.1.a` / `libluajit-5.1.so`. A `.pc` claiming `-lluajit` names a
library that this build does not produce, and a consumer following it fails
at link time with a name that never existed.

**Fix.** The build graph generates the metadata from `etc/luajit.pc` with the
prefix, multilib and relver substituted, exactly as `Makefile:86-91` does,
including the Darwin variants (`Makefile:113-119`): `.dylib` names and no
`-Wl,-E` on Darwin.

`Libs.private` is upstream's own: `-Wl,-E -lm -ldl`. `-ldl` is `dlopen`, which
the FFI needs to load C declarations at run time; a shared build that omits it
links and then fails the first time Lua code calls `ffi.load`.

**Bound.** All platforms; the names differ per platform, the requirement does
not.

## 7. Integrity records must exclude `.git`, and that is easy to get wrong

**Condition.** Generating `UPSTREAM.sha256` from a working tree that is a Git
repository — which every SDK here is.

**Symptom.** A digest run that walks the tree without excluding `.git`
produces a record containing `.git/HEAD`, `.git/config` and the sample hooks.
`sha256sum -c UPSTREAM.sha256` then fails in any clean checkout, and the
failure names Git's own files, which reads like corruption of the source when
nothing of the sort happened.

**Fix.** Exclude `.git` (and the fork's own files, and the fork-extended
`.gitignore`) before hashing, and state each exclusion in the record's own
header. The first version of this file in fact did include eighteen `.git`
paths and was regenerated before anything else was written.

**Bound.** Every integrity record in every SDK, not just this one.

## 8. `.gitignore` here is two grants in one file

**Condition.** The root `.gitignore`, which upstream owns and this fork
extends.

**Symptom.** Upstream's twelve lines are a valid pattern list. Appending a Zig
block below them keeps them working and makes the whole file no longer
byte-identical to upstream, so it can have no digest in `UPSTREAM.sha256` and
no single SPDX identifier.

**Fix.** Keep upstream's lines verbatim at the head, append below, quote
upstream's own digest in the integrity record's header, and record both halves
in `NOTICE.md` and `FORK-LICENSE.md`. This is a deliberate exception, not an
oversight, and it is the only path in the repository without a digest.

**Bound.** Only this file. `src/.gitignore`, `src/host/.gitignore` and
`src/jit/.gitignore` are upstream's and untouched; they keep their digests.

## 9. Nix: refuse cross-compilation rather than guess the target triple

**Condition.** A Nix derivation that runs `zig build install` without naming
a `-Dtarget`.

**Symptom.** Zig's default target is the *build* machine. In a Nix cross
derivation the store path is meant for `stdenv.hostPlatform`, so an unnamed
`-Dtarget` silently produces a library for the wrong architecture — and
`package.nix` is evaluated, not built, so nothing fails at evaluation time.

**Fix.** Compare `stdenv.hostPlatform.system` with
`stdenv.buildPlatform.system` and refuse when they differ. That comparison,
not `builtins.currentSystem`, is what is correct in pure evaluation:
`builtins.currentSystem` reads impurely and is forbidden in a flake.

A **remote builder is not a cross build**: there `buildPlatform` and
`hostPlatform` are the same system even though the machine is a different one,
so the assertion does not get in its way.

**Bound.** The assertion is about Nix. Nothing stops a user from naming the
build graph's own `-Dtarget` outside Nix; that is the build graph's business.

## 10. Two cautions about wording, recorded because they were live here

**"Static" is an artifact, not a closure.** `package.nix` says so in its own
header. It promises `libluajit-5.1.a`, not a wholly static program. A
dependency on `-lm` and `-ldl` is still there in the static variant.

**A shared variant is not a second SDK.** `static`, `shared` and `default` are
three names for one build graph, one module and one typed surface. Only the
linker target differs.

---

## 11. Two issues found in review, and what was done about them

Both were found by reading a peer's file against the pinned C headers, both
were reported to that owner and to the driver, and both were corrected in
place before this file was written. They are recorded because the reasoning
generalises, and because a rule that never records its own near-misses is not a
rule.

### 11a. `lua_version()` is a number, not a string

**Condition.** Any load-time validation that wants to know which Lua release a
provider is.

**Symptom.** `src/lua.h:351` declares
`LUA_API const lua_Number *lua_version(lua_State *L);` and `src/lj_api.c:136-140`
returns `&version`, where `static const lua_Number version = LUA_VERSION_NUM;`.
It is a pointer to a `double` holding `501.0`.
`runtime/library.zig`'s `Config.validate` re-interpreted those eight bytes as
`[*:0]const u8` and compared them with `"Lua 5.1"`. Little-endian `501.0` is
`f4 01 00 00 00 00 00 00`, whose NUL-terminated span is two bytes, so the
comparison could not succeed for **any** provider — including this SDK's own
library. Every runtime load would have been refused with `ValidationFailed`.

**Resolution.** The check compares the pointed-to value:
`@floatFromInt(dispatch.LUA_VERSION_NUM)` on one side, `dst.lua_version(state).?.*`
on the other, both taken from the translation so neither can drift from the
header this build selected. PUC-Rio's Lua 5.5 reports `505.0` and is refused by
value rather than by symbol count.

**Bound.** Every runtime-loaded consumer. Note what this check does *not*
prove: the collector mode, the number mode, the architecture, or the
`luaL_Buffer` size. It proves the library loaded, allocated a state and
identifies itself as Lua 5.1.

### 11b. `lua_newthread` is a constructor, and it was used as a lookup

**Condition.** Any code that wants the `lua_State *` of a coroutine it already
has.

**Symptom.** `lua_newthread(L)` creates a coroutine and *pushes it on L's
stack*; it never returns an existing one (`src/lua.h:185`). `zig/root.zig`'s
`Thread.raw()` called it, so every call allocated a different coroutine, grew
the parent's stack and returned an object that was not the one `resume`,
`status` and `errorMessage` used. `Thread.threadState()`'s fallback had the same
shape: it pushed a new thread and returned it without ever recording it at
`self.index`, so its comment's promise that the handle "stays usable" did not
hold and each call repeated the dead end.

**Resolution.** `Thread` is now a single `raw: ?*c.lua_State` field holding the
pointer `lua_newthread` returned **at creation**, plus `resume`, `status` and
`errorMessage`. There is no lookup path and no fallback, so there is nothing
left that can return a different coroutine from the one the handle names. It is
a field rather than a method, which also removes the collision with `State.raw`.

**Bound.** Every coroutine path. The general shape: a Lua handle is a *slot on
another state's stack*, and re-deriving it means re-running the call that
created it. When a facade needs the pointer, it stores the one it already had.

## 12. The runtime route became an option, not a substitution

**Condition.** Selecting the runtime-loaded configuration. It was originally
documented as a manual substitution in the build graph.

**Symptom.** A substitution works exactly once, by hand, and then the working
tree stops matching every sentence written about it: a reader cannot tell from
the source whether the build in front of them is the linked one, and
`README.md`'s option list has no row for a configuration that is a supported
deliverable with its own gates.

**Fix.** `build.zig` declares `-Druntime`, defaulting to `false`, and
`build_support/graph.zig` branches on it in one place. The runtime branch
imports `runtime/graph.zig`'s `createModule(b, translate, target, optimize)` as
the facade's `c` and links **no** archive into it. The linked branch imports
`translate.createModule()` and links the static library. The library is built
and installed either way, because it is what a runtime build loads.

The one thing a consumer must not do is link the compiled archive into a module
that imports the dispatch. The facade's `c` import *is* the dispatch; a second
reference to the archive lets the linker satisfy those symbols statically, and
the runtime route silently becomes a linked one with no error at all. That is
why the runtime branch links nothing, and why "it loaded but every call was
direct" is the symptom to look for first.

The facade does not need two sources. `zig/root.zig` asks which configuration it
was compiled against with `@hasDecl(c, "rt_runtime_loaded")` and reads
`LoadSource` and `LoadError` off whichever module defines them, so a consumer can
name the two public types without knowing which build it linked against.

**Bound.** Every runtime gate, and only those. Nothing above this line depends
on it: the linked configuration is unaffected and its calls stay direct. The
shared core (`runtime/loader.zig`, `runtime/generate.zig`, `runtime/sync.c`,
`runtime/sync.h`) is in the tree; whether a runtime-loaded build runs is still
an unobserved gate.

## 13. The external unwinder is a link dependency, not a driver courtesy

**Condition.** Linking the native closure on any ELF Unix target.

**Symptom.** The first link attempt failed on **eight** undefined symbols:
`_Unwind_GetCFA`, `_Unwind_SetGR`, `_Unwind_GetIP`, `_Unwind_SetIP`,
`_Unwind_DeleteException`, `_Unwind_RaiseException`, `__register_frame` and
`__deregister_frame`. Upstream declares all eight and defines none. They are the
Itanium C++ ABI unwinder, and libgcc supplies them.

Upstream never trips over this because it never has to think about it: a GCC or
Clang driver links the unwinder in by default, so `src/Makefile` never names it
and `etc/luajit.pc` never lists it. `luajit.pc` therefore understates the real
link line — that is upstream's metadata, and it is one of the reasons this file
records dependencies the `.pc` does not. Zig's C compilation path has no such
driver, so whoever links has to write the dependency down.

**Fix.** `build_support/graph.zig` links `gcc_s` on `.linux`, `.hurd`,
`.freebsd`, `.netbsd`, `.openbsd` and `.dragonfly`. The C side already carried
`-DLUAJIT_UNWIND_EXTERNAL` for the same targets, from `src/Makefile:325` on
Darwin and `:343` for any toolchain whose objects always carry unwind tables.
The two halves now agree: the macro that asks for the external unwinder
(`LJ_UNWIND_EXT`, `src/lj_arch.h:717-721`) and the library that satisfies it.

**Bound.** ELF Unix only; nothing else in the graph changed, and Darwin, Windows
and WASI take different paths. `_Unwind_Find_FDE` (`src/lj_err.c:501`) is a
ninth such name in that file and is deliberately not counted: it is inside
`#if LJ_UNWIND_EXT && defined(LUA_USE_ASSERT)`, and this build defines neither
`LUA_USE_ASSERT` nor `LUA_USE_APICHECK`, so nothing references it. A provider or
a rebuild that turns assertions on needs it, which is a different build.

## 14. A sanitizer that fires on upstream's own decoder is a flag decision

**Condition.** Debug builds, where Zig enables Clang's C undefined-behaviour
sanitizers by default.

**Symptom.** Twenty-two of twenty-nine tests crashed on a signed left-shift
overflow, and all twenty-two were the same line. The pinned ULEB128 decoder at
`src/lj_buf.c:298` reads `(*w & 0x7f) << (sh += 7)`; at `sh == 28` that promotes
a signed byte and shifts it into bit 31. `luaL_openlibs` reaches the decoder, so
the crash is counted once per test that opens the libraries rather than once per
build — which is what makes twenty-two crashes look like twenty-two defects.

**Fix.** The line is upstream's and stays byte-for-byte, so the correction
belongs to the compiler flags and nowhere else. `build_support/graph.zig` adds
`-fno-sanitize=shift-base` to every native translation unit: that one check off,
every other C undefined-behaviour check still on. The narrowing is deliberate —
no bare `-fno-sanitize`, no `-fsanitize-recover`, no `LUA_USE_ASSERT` turned on
to make the code path different.

**Bound.** Every native object, on every target. **The suite has not been re-run
since the flag landed**, so this is a pending gate and not a fix known to work,
and no row of the gate table may be read as passing until it is. A caller who
wants the original instrumentation back can drop the flag; upstream's line then
aborts under Debug, which is the honest answer for a toolchain upstream never
tested against.

## 15. `lua_Integer` is a width, not a promise, and `f64` is the only number

**Condition.** Any decision to widen `lua_Integer`, to parse a decimal string
straight into an integer, or to describe `pushInteger` as making a value
"exact".

**Symptom.** Lua 5.1 has one number type. `LUA_NUMBER` is `double`
(`src/luaconf.h:119`, with `LUA_NUMBER_DOUBLE` defined beside it), so a value
that has become a Lua number has been an `f64` on every target — there is no
per-platform exception to document. `LUA_INTEGER` is `ptrdiff_t`
(`src/luaconf.h:106`), so `lua_Integer` is 32 or 64 bits according to pointer
width, which is a *different kind* of statement from "64-bit".

The string path is where this bites. `lua_tointegerx` (`src/lj_api.c:422-445`)
calls `lj_strscan_number`, and that scanner computes a `lua_Number` and only
then asks whether the **double it already computed** converts back to an
integer exactly (`src/lj_strscan.c:526-529`). 2^53+1 therefore arrives as 2^53.
An oracle written the way a Lua 5.3+ reader expects — "an integer literal keeps
its digits" — fails, and the tempting repairs are to widen the scan or
special-case it.

**Fix.** Neither. `Number` and `Integer` stay two distinct types so every
narrowing is visible in a signature; `toIntegerX` and `toNumberX` exist so a
conversion and a refusal are different answers; and the boundary is written down
with its source lines in [`README.zig.md`](README.zig.md#numbers). A decimal
string no double holds loses its low bits **inside the library, before any Zig
code runs**. The fix for an assertion that expected the exact value is the
assertion.

**Bound.** Every target and every optimize mode. An integer that goes in as one
through `pushInteger` and comes back through `toIntegerX` is exact; one that
arrives as a Lua number or out of a string is not, and no target changes that.
`"3.5"` answers `3` rather than null, because `toIntegerX` casts
(`src/lj_obj.h:1010`) — that is a conversion the caller opted into by using the
`X` form, not a rounding surprise.

## 16. Ownership is a pair, and a coroutine is a slot on someone else's stack

**Condition.** Any state opened through `init`, any `setAllocator` call, and any
`Thread` or `Buffer` that outlives the statement that made it.

**Symptom.** Three ways to get this wrong, all of which look correct until they
are not.

1. `init` could have been written as `initWithAllocator(null, null)`. It is not,
   and must not be. `luaL_newstate` hands `lua_newstate` an internal sentinel
   (`src/lib_aux.c:373-377`), `lua_newstate` answers it with the library's own
   pooled allocator (`src/lj_state.c:262-267`), and the state itself is then
   allocated *through the callback* (`src/lj_state.c:269`). A null callback is a
   call through a null pointer.
2. `setAllocator` returns the pair it replaced and frees nothing
   (`src/lj_api.c:1297-1302`). Blocks taken under the old callback are still
   outstanding when the next allocation already goes to the new one, and
   `lua_close` releases what is left through whichever callback is installed at
   that moment (`src/lj_state.c:243`), not the one the state was opened with.
   Swapping the library's own allocator away and back also loses its pool,
   because `lua_close` destroys that pool only while the library's callback is
   still the installed one (`src/lj_state.c:238-243`).
3. A `Thread` is a slot on the parent state's stack, not an independent
   allocation. `newThread` pushes the coroutine onto the parent, and that push
   is what keeps it alive; drop the slot, collect, and the handle dangles.

**Fix.** `AllocatorPair` is one nominal type, so the pair `State.allocator`
reads back and the pair `State.setAllocator` installs cannot be two anonymous
structs that happen to match; it is read back with `lua_getallocf` because the
library is the only place that knows. `Thread.raw` is a field holding the
pointer `lua_newthread` returned **at creation** (§ 11b), and `deinit` is
idempotent, so the second call is a no-op rather than a double free.

**Bound.** Every consumer. `lua_close` is the only thing that releases state and
it releases through the allocator installed when it runs; nothing here can
detect a `deinit` that runs while a `Thread` or a `Buffer` is still in use. A
`Buffer` must be initialized *in place* on the variable that stays, because
`luaL_buffinit` stores a pointer to the array inside the struct it was given.

## 17. An optimized translation declares a different set of externs

**Condition.** Building the runtime route (`-Druntime=true`) at
`-Doptimize=ReleaseSafe`, the mode whose C front end turns `_FORTIFY_SOURCE`
on. `translate-c` reads the target's headers with the *build's* configuration,
and the configuration is not a separate question from the target.

**Symptom.** The load fails with `MissingSymbol` against a provider that is
correct: it exports every entry point `src/lua.h`, `src/lauxlib.h`,
`src/lualib.h` and the generated `src/luajit.h` declare except `lua_setlevel`,
which no provider can export. On Linux the mistake can also hide rather than
fail, because `dlsym` on the provider's handle searches the provider's
dependencies and libc is one, so the names resolve to the C library rather
than to LuaJIT; it surfaces where there is no libc to borrow from.

The cause is `runtime/graph.zig`'s `libc_noise`, the list of `extern`
declarations the C library provides, which the generator leaves `direct` rather
than routing to the provider. It was measured across all 59 targets, in one
configuration. The `-Doptimize=ReleaseSafe` build adds
`-D_FORTIFY_SOURCE=2` and the other three do not; glibc defines
`__USE_FORTIFY_LEVEL` only when `_FORTIFY_SOURCE > 0` **and** `__OPTIMIZE__ > 0`
(`lib/libc/include/generic-glibc/features.h:454-473`), and
`generic-glibc/stdio.h:956-959` then includes `bits/stdio2-decl.h`. That header
declares the fortified `<stdio.h>` family — a `__*_chk` per fortified function,
a `__*_alias` redirect back onto the plain function, and a `__*_chk_warn`
sibling — and `src/lauxlib.h:13` reaches `<stdio.h>`, so a fortified
translation sees declarations an unfortified one does not. The measurement was
right about targets and silent about modes.

Observed shape: the ReleaseSafe dispatch required **163** names where every
other configuration's required **148**, and the fifteen names the two differ
by are exactly fifteen of that family.

**Fix.** List them. Twenty-three names are added to `libc_noise`, each read out
of the pinned Zig distribution's `bits/stdio2-decl.h` and cited by line in the
comment above the list: the fifteen the fortified translation of this pin
reaches, and eight that sit behind `__USE_GNU` or `__GLIBC_USE (DEPRECATED_GETS)`
and are listed because the list is a union across targets rather than this
one's. They are listed by exact name, not by a `__` prefix rule: a prefix rule
would also swallow a legitimate name this file cannot see.

**Bound.** Every runtime gate at `-Doptimize=ReleaseSafe`, and nothing else. The
linked configuration never consults this list, and Debug, ReleaseFast and
ReleaseSmall never declare the family, so their tables are unchanged. With the
names de-routed the required table is the same 148 header entry points in all
four modes, which is what `README.zig.md`'s provider contract already states.
The repair is unobserved: both ReleaseSafe gates and the real consumer are
unrun since it landed.

## 18. Two ways the build graph could describe a different library than it built

**Condition.** Two unrelated questions, one about where the install root comes
from and one about what reaches the nested consumer build. Both are properties
of the build graph rather than of the source, which is why neither shows up in
`src/` and both change what a gate proves.

### 18a. A dependency's install prefix is a cache directory, and it was becoming `LUA_ROOT`

**Symptom.** `lua_root` defaulted to `b.install_prefix` whenever that was
absolute. `createChildOnly` does not pass a `--prefix` down: it replaces the
child's prefix with `<cache>/i/<hash>` (`std/Build.zig:721-723`), which is
absolute. So on the `dep.module("luajit")` route — the one `consumer/` exists to
prove — `LUA_ROOT`, `LUA_LJDIR` and the delivered CLI's `package.path` could all
name a directory the cache manager is free to delete. Nothing fails at build
time; the closure is simply wrong by the time anyone reads it. `luajit.pc` is
not in that list and never was: it keeps `prefix=${pcfiledir}/../..` and
derives nothing from this build's root.

**Fix.** `install_root(b)`, which takes an absolute prefix that is **not**
inside the build cache. Asking whether the caller *named* `--prefix` is not
available: the build runner parses `-p`/`--prefix` itself
(`lib/compiler/build_runner.zig:165-166`) and hands it to
`resolveInstallPrefix`, so unlike `-Dtarget` it never reaches
`b.user_input_options`, and a `contains("prefix")` test answers false every
time. Location separates the two cases: the digest directory `createChildOnly`
writes is the only prefix inside the cache, and both a real `--prefix` and the
`<build_root>/zig-out` default (`std/Build.zig:732-733`) are outside it.

**Bound.** Every configuration reached as a dependency. A top-level build's
`--prefix` is outside the cache and still the default, so nothing changes for
it. `-Dlua-root` still overrides everything, and still refuses a relative path.

### 18b. `-Dcpu` was dropped on the way to the consumer build

**Symptom.** `runConsumer` passed `-Dtarget`, `-Doptimize`, `-Dlinkage` and
`-Druntime`, and dropped the CPU. `-Dtarget=` carries architecture, OS and ABI,
and `Target.Query.zigTriple` says nothing about the CPU at all: an ARM target
crosses as `arm-linux-musleabi`, which does not say whether the core has VFP or
which PCS it uses. `build_support/abi.zig:177-186` derives `LJ_ARCH_HASFPU` and
the soft-float ABI from exactly those features, and DynASM's FPU/HFABI choice
follows from them, so the nested build configured a different VM than the one it
was testing and then agreed with its own checks.

**Fix.** Forward `-Dcpu` when the caller named one. `b.user_input_options`
holds exactly what the command line carried — `build_runner.zig:154` for
`-Dname=value` and `:157` for `-Dname` — so `contains("cpu")` is true for a
named `-Dcpu=` and stays false for a `-Dtarget` that implies a model. The value
is `target.query.serializeCpuAlloc` rather than the text the caller typed:
`std.Build` keeps the typed text inside a private type this file cannot read,
and the query is what every later decision is resolved from.

The comment above `runConsumer` also used to claim that `-Dlua-root` "is not
forwarded and needs no forwarding" because the nested build resolves it from its
own `--prefix`. That was never true. The helper passed no `--prefix` at the
time, and a `--prefix` would not have carried the root in any case: the library
reaches this proof as `consumer`'s `b.dependency` child, and `createChildOnly`
replaces that child's install prefix with a cache digest directory whatever the
nested build was told (`std/Build.zig:721-723`). The option carries what no
prefix can. `consumer/build.zig` declares `-Dlua-root` and hands it to its own
`b.dependency("luajit", ...)` unchanged, which is what makes it legal: the
build runner rejects an option no build script reads (`std/Build.zig:1644-1655`,
from `build_runner.zig:487`). What travels is the resolved root,
`lua_root_option orelse install_root(b)`, so the consumer links the library this
build configured rather than one that answers the same question again.

**Bound.** `zig build consumer` on a target whose CPU features matter: ARM,
where `has_fpu` and `soft_fp` are read off those features. x86_64 and the other
targets whose macro choice does not read them are unchanged. The condition does
not fire for a bare `-Dtarget`, and that is not a gap: with nothing named both
graphs resolve `b.graph.host` (`std/Build.zig:2704-2707`), and a bare `-Dtarget`
leaves both on the cross query's `baseline` model
(`std/Target/Query.zig:497-502`).

---

## 19. The host generator is a program too, and it has a pointer width

**Condition.** `-Dtarget=<32-bit triple>` on a 64-bit build machine.

**Symptom.** `buildvm -m elfasm` exits 1 with `Error: pointer size mismatch in
cross-build.` and `Try: make HOST_CC="gcc -m32" CROSS=...`, and the same text
comes out of all six of its invocations, so the cell never reaches its library.

**Why it happens.** `src/host/buildvm.c:449-453` guards its own `main()` with
`sizeof(void *) != 4*LJ_32+8*LJ_64`, and `LJ_32`/`LJ_64` come from
`LJ_ARCH_BITS` (`lj_arch.h:671-677`), which this graph pins from the **target**
through `applyTargetArchMacros` — the same pinning `src/Makefile:203` does when
it puts `$(TARGET_ARCH)` on `HOST_ACFLAGS`. So the generator is a host program
configured for the target, and its own machine word is the one thing upstream
still asks the build to match. Two host predefines leak the same way on the same
cells: PowerPC's `LJ_ARCH_BITS` is read from `_LP64`
(`lj_arch.h:324-331`), which glibc defines on any 64-bit host, so a
PowerPC-32 target made the generator believe it was compiling for PPC64 and
stopped at `lj_arch.h:369`.

**Fix.** `generatorHostTarget` in `build_support/graph.zig`: the build machine
when `std.Target.ptrBitWidth()` already equals `Selection.bits`, otherwise the
same operating system with the same CPU family narrowed to 32 bits — musl on
Linux, so the result is a static program with no dynamic loader and no
requirement that the machine carry a 32-bit glibc — and a named panic for a
build machine with no 32-bit form and for a 64-bit target on a 32-bit machine.
That is upstream's `HOST_CC="gcc -m32"` (`src/Makefile:32`, `:187-188`) with the
word "host" kept honest: the generator still runs on the build machine and still
emits the target's files, and nothing about the target is guessed.

**Targets bound.** Every 32-bit target that LuaJIT 2.1 supports: x86, ARM,
Thumb, MIPS32 on Linux, NetBSD, OpenBSD, FreeBSD and Windows. PowerPC-32 comes
with the `_LP64` half. A 64-bit target is untouched: `generatorHostTarget`
returns `b.graph.host`, so the native build and the six `check` cells that
already compiled are byte-for-byte the same command line. `minilua` is not on
this route and does not need to be: `src/host/minilua.c` includes C library
headers only, and both scripts it runs read text and `-D` arguments.

**How the generator runs.** The generator is a program of the **build
machine's** family narrowed to 32 bits, never of the target's — that is what
upstream's `HOST_CC="gcc -m32"` is, because it is the host compiler that gets
`-m32`. So it runs wherever the machine runs its own 32-bit programs, natively
on x86_64 Linux, and needs the build runner's executor (`-fqemu`) exactly where
the test binary would. `cross-test` supplies that executor for the cells whose
target is the build machine's own family, because
`~/.local/lib/cross-test/run_policy.zig` prefixes every `Run` step whose
executable matches the cell target's architecture and OS; for a MIPS or ARM
cell the prefix does not apply to the generator, and the generator runs the
same way it does in a plain `zig build`.

### 19a. The generator's view of the JIT has to be the library's

`src/host/buildvm_lib.c:379-395` scans `lib_jit.c` with `#if LJ_HASJIT`
resolved from **buildvm's own** `lj_arch.h`, while the library's is compiled
with the **target's** predefines. `lj_arch.h:130-133` reads `TARGET_OS_IPHONE`,
which Apple's toolchain defines for iOS, tvOS, watchOS, visionOS and Mac
Catalyst — a Catalyst target reaches `LJ_TARGET_IOS 1` exactly as an iOS target
does. A generator on a non-Apple host therefore saw `LJ_HASJIT 1`, wrote the
`jit.util` entries into `lj_libdef.h`, and both `*-maccatalyst` cells failed on
seven of them. Upstream's own fix is a define on the host line
(`src/Makefile:373-376`, inside the `HOST_SYS != TARGET_SYS` guard at `:362`),
and that is now what `addBuildvm` adds, pinned on the generator's line only:
the library's toolchain already answers `TARGET_OS_IPHONE`, and restating it
would be a claim about a target this graph cannot see.

The other half of the Catalyst story is one token in the file that owns the OS
mapping, and it is now there: `build_support/abi.zig:131-143` groups
`.maccatalyst` with `.macos, .ios, .tvos, .watchos, .visionos`. Zig 0.16 gives
Catalyst its own `Os.Tag` (`std/Target.zig:42`) and its own `.macho` case
(`:1049`), while upstream says it is Darwin and iOS at once —
`-DLUAJIT_OS=LUAJIT_OS_OSX` for Darwin (`src/Makefile:370-372`), the same value
with `-DLUAJIT_TARGET_IPHONE=1` for iOS (`:373-376`), and `lj_arch.h:81` reading
`LUAJIT_OS_OSX` from `__MACH__ && __APPLE__`, which Catalyst satisfies. With
`Os.other` the mapping had asked `buildvm` for `elfasm` (`abi.zig:318-324`), so
the ELF directives in `src/host/buildvm_asm.c:195-232` reached a Mach-O
assembler; the same answer had taken `LUAJIT_OS_OSX` off the generator's line,
dropped `LUAJIT_UNWIND_EXTERNAL` from the library's
(`build_support/graph.zig:826-831`, upstream `src/Makefile:325` and `:343`) and
kept `SED_PC`'s Darwin `-Wl,-E` removal (`src/Makefile:118`) from reaching
`addPkgConfig`. Nothing else was changed there and no C source was touched.

### 19b. What the same run did not fix, and must not be written up as fixed

* `mips64-linux`/`mips64el-linux`: `src/lj_mcode.c:55-56` calls
  `__clear_cache` under `#elif defined(__GNUC__) || defined(__clang__)` and Clang
  declares it for these two targets nowhere;
  `mips64-openbsd`/`mips64el-openbsd` fail on that line alone. It is upstream's
  primitive and an upstream C source, so it stays a boundary.
* The same cells also report `ignoring '-fno-PIC' option ... N64 ABI`. No
  `-fPIC`/`-fno-PIC` is on any command line this graph writes — `Module.pic` is
  null and `appendZigProcessFlags` emits nothing for null
  (`std/Build/Module.zig:252`, `:554`) — and the identical warning appears on a
  `zig cc -E -target mips64-linux` line this graph wrote, in a run of a package
  whose own build then succeeded. Reported as observed; not attributed to this
  graph and not "fixed" by it.
* `thumb-windows`: `PEOBJ_TEXT_FLAGS` exists for `LJ_TARGET_X86`,
  `LJ_TARGET_X64` and `LJ_TARGET_ARM64` only
  (`src/host/buildvm_peobj.c:83-107`), so LuaJIT 2.1 has no PE object emitter
  for 32-bit ARM. Upstream's own gap.
* The unsupported architectures keep refusing at configure time
  (`build.zig:309-318`, upstream's text and `lj_arch.h:69`/`:369-370`), while
  `check` observes the same refusal the other way
  (`build.zig:625-667`). Both are the refusal; neither was turned into a green
  cell.

## 20. The installed `luajit.pc` must name the unwinder its archive needs

**Condition.** Any `pkg-config --static --libs luajit` consumer, on the ELF Unix
targets section 13 names.

**Symptom.** A C consumer built from a static install of this SDK with
`pkg-config --libs --static` failed to link on exactly the eight names section
13 lists — `_Unwind_GetCFA`, `_Unwind_SetGR`, `_Unwind_GetIP`, `_Unwind_SetIP`,
`_Unwind_DeleteException`, `_Unwind_RaiseException`, `__register_frame` and
`__deregister_frame` — every one of them reported out of `libluajit-5.1.a`'s
`lj_err.o`. The flags that did reach the command line were
`-lluajit-5.1 -Wl,-E -lm -ldl`, which is `etc/luajit.pc:23-24` complete: the
installed file described a link that cannot close.

The same install's **shared** variant links, and the reason is visible in the
library rather than in the flags. `libluajit-5.1.so` carries its own unwinder —
`_Unwind_RaiseException`, `_Unwind_SetGR`, `_Unwind_GetCFA`, `_Unwind_Resume`,
`__register_frame` and the rest are local symbols compiled in from
`UnwindLevel1.c` and `libunwind.cpp`, and no `libgcc_s.so.1` appears among its
`NEEDED` entries. The archive carries none of them, because a static library is
a pile of objects and links nothing.

**Fix.** `addPkgConfig` in `build.zig` rewrites the `Libs.private` line to
`-Wl,-E -lm -ldl -lgcc_s` on the targets `build_support/graph.zig` already links
`gcc_s` for — `.linux`, `.hurd`, `.freebsd`, `.netbsd`, `.openbsd`,
`.dragonfly` — and leaves upstream's three flags on every other target. The
template is untouched: `etc/luajit.pc` is still read and rewritten, never
copied, so the bytes in `etc/` are the ones `UPSTREAM.sha256` records and the
correction lands in the rendered file a consumer actually reads.

**Bound.** `Libs.private` is read only by `pkg-config --static`, so a shared
consumer's flags are unchanged. The library named is the one the build graph
already names for the same target, so the metadata and the graph cannot drift
apart silently. The in-tree `header-check` step reads the same two fields by
hand (`addHeaderCheck` in `build.zig`) and is not changed by this section; it
has not been run against a static install here, so what that step's link does
with the eight names is not recorded as either working or failing.

## 21. A callback is not told which event it subscribed to, and `ffi` is not a global

**Condition.** Writing anything that observes the JIT from Lua, or reaches the
FFI from a script — the self-check, a consumer, a test.

**Symptom.** One run of `zig build native-test` against a fresh prefix reported
`the JIT compiled at least one trace: 0 trace events` and `ffi table present:
nil`, then died on `attempt to index global ffi`. Both were mistakes of shape
on a build whose JIT did compile a trace and whose FFI did call into libm.

* `jit.attach(cb, "trace")` subscribes `cb` to an event. The argument it is
  handed is what the occurrence *is*: `"start"` when a trace's machine code is
  linked in, `"stop"` when recording finished, `"abort"` when it did not, and
  `"flush"` (`lj_trace.c:474-488`, `:562-566`, `:626-646`, `:299-301`). Nothing
  ever receives the string `"trace"`. Upstream's own `jit.dump` is the worked
  example: `dump_trace(what, ...)` switches on those four strings
  (`src/jit/dump.lua:566-596`). Counting `what == "trace"` counts nothing,
  always, which is worse than no check: it reports a working engine as silent.
* `ffi` is reachable by `require` and by nothing else. `luaL_openlibs` registers
  `{ LUA_FFILIBNAME, luaopen_ffi }` into the registry's `_PRELOAD`
  (`src/lib_init.c:32-37`), which is `package.preload`; nothing puts it in `_G`.
  A script that indexes the global `ffi` reports a complete build as broken.

**Fix.** `build_support/native_selfcheck.lua` counts `"stop"` and reaches the
FFI by `require`, with the two FFI checks guarded so a build without FFI reports
one failure instead of dying on an index. `build.zig` makes `native-test`
depend on the install step, because the `jit.*` modules the script requires are
written only there and the CLI resolves them through `LUA_JPATH`
(`luaconf.h:56`, `:63`) with `LUA_LJDIR` compiled in as
`<install root>/share/luajit-2.1`.

**Bound.** A stopped trace is a compiled trace, and an aborted one is not
counted; the check is still a count and was not relaxed to a flag. The FFI
checks are not replaced by a presence test: `ffi.cdef` and a real `ffi.C.sqrt`
call remain, and those are what a build with `LUAJIT_DISABLE_FFI` fails on. No
module was dropped from the set the script requires, and the JIT and FFI
expectations are unchanged in strength. Depending on the install step makes
`native-test` build and stage the tree it reads; that is the whole cost.

## 22. A `--prefix` the nested build can use, and a root that no prefix reaches

**Condition.** `zig build consumer`, and every other invocation of the
`runConsumer` helper.

**Symptom.** The helper handed the nested build no prefix, so `consumer/`
resolved its own `consumer/zig-out` and `b.installArtifact(exe)` wrote the
consumer program into the source package whatever `--prefix` the outer build
was given. A caller who named an external prefix still got an artifact inside
the checkout, which is what this SDK's own tasks exist to avoid.

**Fix.** Compare `b.install_prefix` with `<build root>/zig-out` and hand the
value on as two tokens when the two differ. A relative value is made absolute
against `b.graph.cache.cwd` first, because the run step's working directory is
`consumer/` and a relative prefix resolves there rather than against this
build's root. `DESTDIR` needs no forwarding: the nested build inherits the
environment this one ran with.

**What it does not do.** It does not carry `LUA_ROOT`, `LUA_LJDIR` or
`LUA_MULTILIB` into the dependency. The library reaches this proof as
`consumer`'s `b.dependency` child, and `createChildOnly` replaces that child's
prefix with `<cache>/i/<hash>` (`std/Build.zig:721-723`) whatever the nested
build was told. `-Dlua-root` carries the resolved root past that hop, and
`install_root` still refuses a prefix inside the build cache (§ 18a).

**Bound.** A caller who named no prefix passes no argument, so the nested build
resolves `consumer/zig-out` exactly as it did before. The step still asks for
`run` on every target, and forwarding a prefix changes nothing about which
executor `Step.Run` may use.

*(Superseded in part by § 24: the step no longer asks for `run` on every
target, but for whatever `hostCanExecute` answers, which is the question
`Step.Run` asks. The prefix rule above is unchanged.)*

**Observed, 2026-10-04.** The relay was exercised, not only argued. In the
driver's nested-delivery epoch all nine LuaJIT rows recorded the prefix as
present, propagated and resolving outside this SDK tree, and every captured
nested command line carried the caller's `-Dtarget`, `-Doptimize`, `-Dlinkage`
and `-Druntime`, the named `-Dcpu`, the resolved `-Dlua-root`, `-j8 --summary
all`, both cache directories and `--prefix`. Those rows named an external
prefix, so `-Dlua-root` and `--prefix` held the same directory there. They are
different values with different jobs: the prefix decides where the consumer
program lands, the root decides what the library compiles in, and
`install_root` still refuses a prefix inside the build cache.

## 23. The architecture selector is a translation, and a translation can invert a name

**Condition.** Any MIPS target, in both its big-endian and little-endian
spellings, on the 32-bit and the 64-bit branch.

**Symptom.** Nothing failed to build, which is what made this one easy to miss.
`Selection.big_endian` is documented as `LJ_ARCH_ENDIAN == LUAJIT_BE`
(`lj_arch.h:14-15`) and both MIPS branches assigned
`Cpu.Arch.endian() == .little`. `targetArchMacros` read the field as
little-endian and emitted `-D__MIPSEL__=1`, which `lj_arch.h:401` turns into
`LUAJIT_LE` at `:419`, so the C side stayed right. `dynasmDefines` read the
same field as big-endian and emitted `ENDIAN_BE`. That define is read on both
branches: `src/vm_mips.dasc:204-220` takes `FRAME_PC`, `FRAME_FUNC`, `HI`, `LO`,
`OFS_RD`, `OFS_RA` and `OFS_OP` from `ENDIAN_LE`, and
`src/vm_mips64.dasc:210-222` takes `HI`, `LO` and the same three `OFS_*` values
for the 64-bit register and operand layout. It gates the JIT paths too, at
`vm_mips.dasc:2982`, `:4813` and `vm_mips64.dasc:3092`, `:4998`. So a
little-endian MIPS target carried a big-endian frame, register and operand
layout in its generated VM on either branch, and agreed with its own checks.

**Fix.** Both branches assign `== .big`, and the MIPSEL macro is emitted when
`!s.big_endian`. One field, two consumers, and the negation is now stated once,
where `lj_arch.h:401` and `:419` state it.

**R6 is a second hole of the same kind.** `LJ_TARGET_MIPSR6`
(`lj_arch.h:402-405`) is derived from `__mips_isa_rev >= 6`, which `std.Target`
does carry, so `mipsIsR6` turned it into `Selection.arch_version` 60 and
`dynasmDefines` passed that on as `VER`. No `vm_*.dasc` reads `VER`, and
`vm_mips64.dasc` reads `MIPSR6` 46 times, so every one of those guards took the
non-R6 arm. `MIPSR6` is emitted now, for `.mips64` at version 60. `.mips` gets
none, because the header's `LJ_TARGET_MIPSR6` is in the 64-bit branch and
`vm_mips.dasc` never reads the name.

**Bound.** `SQRT` and `GPR64` stay unpassed, and not because no `.dasc` reads
them: `vm_ppc.dasc` reads `SQRT` once and `GPR64` 33 times. They are
unreachable instead, since `_ARCH_PPCSQ` is a PowerPC-64 macro and `select`
refuses `.powerpc64` (`lj_arch.h:369-370`), and no accepted target is a
console build. `ROUND` is read by nothing. Only `MIPSR6` was a genuinely
missing emission, and every non-MIPS target resolves exactly as it did. No
upstream source changed.

**What one attempt shows, 2026-10-04.** `-Dtarget=mips64-linux-muslabi64
-Dcpu=mips64r6 -Doptimize=ReleaseSafe` was run and recorded at
`/home/tmp2/gertullj/scratch/foundation-libs/review-contract-probes/evidence/after-20261004T213021Z/luajit-r6-mips64-compile.json`.
It exits 1 on two diagnostics: the N64 `-fno-PIC` driver line, repeated once
per translation unit, and the undeclared `__clear_cache` at
`src/lj_mcode.c:56:3`.
The native compile is therefore a boundary, and it is § 19b's upstream
primitive in an upstream C source rather than this section's subject. The
generator half is observed: **5610** encoded words from **1503** matched
`.long` directive lines carry **63** R6 select forms and **0** R2 ones, so
`selected_mips_isa` is `r6`, and the ISA is read out of `seleqz`/`selnez`
against `movz`/`movn` in the encoded words rather than out of branch counts.
That is a codegen result, not a run. No R6 program was executed, and no
pinned cross-test cell names this target.

## 24. The consumer step chose `run` before asking whether this host can run it

**Condition.** `zig build consumer` with a `-Dtarget` this build machine cannot
execute, and no executor the build runner was told it may use.

**Symptom.** `runConsumer` passed `run` unconditionally (`build.zig:628` before
this section), so a foreign target reached a nested `Step.Run` with nothing able
to spawn it. The step did not install anything and call that a pass — it failed,
and the failure was the runner's rather than a statement about this SDK — but
the step's own contract was wrong. It promised a run on targets where only a
compile is possible, which left the external matrix's build-only rule to be
enforced outside the step that made the promise.

**Fix.** One predicate, `hostCanExecute` (`build.zig:736`), asks
`std.zig.system.getExternalExecutor` the question `Step.Run` asks about the
artifact it is about to spawn, with the build runner's own executor switches in
`allow_*` and the consumer's libc requirement in `link_libc`; `runConsumer`
takes `run` or `install` from its answer. `.qemu` is gated apart, because a
cross GNU-libc target with no runtimes directory is a step `Run` fails rather
than skips.

**Targets bound.** Every build step that chooses between running and only
installing a nested program, in any target. A target this host executes
natively keeps the same nested command line, so `CHANGELOG.md` § 24's nine
observed rows are unaffected. A target it cannot reach installs
`consumer/zig-out/bin/luajit-consumer`, or the same path under a forwarded
`--prefix`: compile and link evidence, never a passing consumer.

**What did not move.** The target query, the optimize mode, the linkage, the
dispatch mode, the conditional `-Dcpu`, `-Dlua-root`, the executor switches,
`--libc-runtimes`, `-j8 --summary all`, both cache arguments, the `--prefix`
rule and `b.args` behind `--` stand as § 21 and § 22 recorded them, as does
`run.has_side_effects`. No option, default, native source, header, test, data or
licence file changed, and no forwarding test was added.

**Not observed.** Nothing has been built or run over this source.
`PENDING-VERIFICATION`.

---

## Open items for the driver

Nothing below is a limitation of the project. Each is an action only the
driver can take, listed so it is not mistaken for a boundary.

* **Re-run everything, starting with what failed.** The gate table is
  [`README.md`](README.md#3-build-run-and-test-matrix); the Zig-surface subset is
  [`README.zig.md`](README.zig.md#verification-status). The one Debug run on
  record reported **29 tests: 5 pass, 2 fail, 22 crashed**, and that run
  predates `-fno-sanitize=shift-base`. Three things have been observed since:
  `zig build native-test` at **49 of 49 steps, 0 failures** against a brand-new
  prefix; the 53-platform matrix, once, at `pass 0`, `build_only 11`,
  `build_fail 39` and runtime `fail 3` (`CHANGELOG.md` entry 26); and the
  compile-only baseline at exit 0. What is still owed is the same list against
  the current source — `zig build` end to end, `test` in ReleaseSafe, `smoke`,
  `header-check`, `check`, `consumer`, the runtime-loaded consumer, the
  `static`/`shared` derivations in all four optimize modes, a 53-cell replay that
  actually covers entry 27's static host generator, and the installed-C and
  fetched-consumer paths.
* **Locks are the driver's.** `flake.lock` is in this tree and resolves
  `nixpkgs` to a locked input, which is what `flake.nix:20-22` asks for; it is
  generated and owned by the driver, not derived by this package, and nothing
  in it is invented here. `devenv.lock` does not exist here and none was
  invented for it: `devenv.yaml:8-11` states which `nixpkgs` revision it wants
  precisely so that the lock records that revision when the driver generates
  one.
* **Two of the six baseline cells are a refusal, and that is the result.**
  `src/lj_arch.h:54-70` selects x86, x64, arm, arm64, ppc, mips32 or mips64 and
  its `#else` at `:69` is `#error "Architecture not supported..."`, so
  `riscv64-linux-gnu` and `wasm32-wasi` cannot build this source. `check` runs
  each target's **own** preprocessor over `src/lj_arch.h` and *requires*
  `lj_arch.h:69`'s `#error`, so a passing cell has observed the refusal with
  that target's real compiler rather than taken anyone's word for it.
  The driver records those two cells as an observed boundary, not as coverage,
  and does not count them as passes.
  `aarch64-macos-none` and `x86_64-windows-gnu` are in LuaJIT's chain; whether
  this build actually produces a `.dylib` or a `.dll` there has not been
  observed and is not claimed.
* **The runtime route is wired and unrun.** `-Druntime` is a declared build
  option defaulting to `false`, and `build_support/graph.zig` branches on it in
  one place (§ 12). `runtime/loader.zig`, `runtime/generate.zig`,
  `runtime/sync.c`, `runtime/sync.h`, `runtime/graph.zig` and
  `runtime/library.zig` are all in the tree: nothing has to be copied in before
  this SDK compiles, and no build-side change is outstanding. What is left is
  entirely observational. No runtime-loaded build has been run, so the load
  contract in [`README.zig.md`](README.zig.md#runtime-loading) — explicit
  request only, no path-to-system fallback in either direction, idempotence,
  `ProviderMismatch` on a second *different* request, `ReentrantLoad`, and the
  panic before the first call in all four optimize modes — is source-confirmed
  and gate-unconfirmed.
  **Bound:** every runtime gate; nothing above this line depends on it.
* **`package.nix` was written against the contract's install closure.** If the
  build graph installs a different path set — a different `.pc` location, a
  different header directory, `doc/`, or `COPYRIGHT` somewhere other than
  `$out/COPYRIGHT` — `package.nix`'s `installCheckPhase` and `postInstall` are
  where the correction lands, and only there. One writer per path: the
  derivation never duplicates what the graph installs, and the install check
  fails loudly if the graph left a licence file out rather than shipping an
  output that has lost it.
* **§ 19 landed unrun, with four corrections behind it.** `zig build test
  -Dtarget=x86-linux -j8 --summary all` exercises the 32-bit generator end to
  end; `-Dtarget=aarch64-netbsd` the completed translation route;
  `-Dtarget=aarch64-maccatalyst` both halves of the Catalyst story — the
  generator's JIT macro in `graph.zig` and the OS grouping in `abi.zig`. The
  53-cell run needs no new switch for the 32-bit generator; see § 19.

## See also

* [`CHANGELOG.md`](CHANGELOG.md) — the numbered changes
* [`UPSTREAM.md`](UPSTREAM.md) — the pin, the closure, the ABI facts read out
  of the source
* [`NOTICE.md`](NOTICE.md) — the per-file licence audit