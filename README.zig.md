# README.zig.md — the Zig interface

The reference for the Zig side of this SDK: what the module publishes, what the
raw route reaches, how runtime loading works, and what a loaded provider must
actually satisfy.

[`README.md`](README.md) covers the native source and build, the gate table and
consumption. [`UPSTREAM.md`](UPSTREAM.md) covers the pin, the closure and the
ABI facts read out of upstream's source. Nothing here repeats those.

Every statement in § 1 through § 5 is `SOURCE-CONFIRMED`, read out of a file in
this repository. § 6 is the one place a run appears, and the run it reports
failed.

---

## 1. The module

The build graph publishes a public module named **`luajit`**. `zig/root.zig` is
its root source file.

There is exactly one native route into this SDK, and it has two faces:

* the **raw route**, `luajit.c`, which is the translated native module
  unchanged — every type, constant, macro-derived value and `extern`
  declaration `zig translate-c` produced from the four public headers;
* the **typed surface**, ordinary Zig declarations over that same module.

`c` is the *same* module in both the linked and the runtime-loaded
configuration, and its types are the *same* types. Nothing is re-declared into
a parallel namespace and cast between, because a nominally distinct copy of a
`luaL_Buffer` or a `lua_State` layout would be a second, unchecked ABI.

### What the translation reads

`build_support/translate.h` is the single translation unit, and it names four
headers and nothing else:

```c
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <luajit.h>
```

Three decisions in that file are load-bearing, and all three are its own
comments:

* **`luajit.h` is the generated one.** `src/luajit_rolling.h` ends in
  `#error "DO NOT USE luajit_rolling.h -- only include build-generated
  luajit.h"`, so translating it would be translating a deliberate refusal. The
  generated header is produced by `src/host/genversion.lua` and lands in the
  build cache; the build graph puts **its directory on the translation line**,
  for the same reason it is on the compile line.
* **`lua.hpp` is deliberately absent.** It is a C++ header that `Makefile:98`
  installs for a C++ consumer, and `zig translate-c` parses C. A C++ consumer
  including `<lua.hpp>` gets it from the installed header tree.
* **Angle brackets, not quotes.** A quoted include also searches the directory
  of `translate.h`, which would let a stray `lua.h` or `luajit.h` beside the
  package root win over the ones the build graph put on the line.
  `lua.h` includes `"luaconf.h"` by itself (`lua.h:16`), so `luaconf.h` is
  reached through it rather than named twice.

So the translated namespace contains everything the four headers declare, which
is **149 functions** — 88 in `src/lua.h`, 43 in `src/lauxlib.h`, 13 in
`src/lualib.h` and 5 in the generated `luajit.h` — plus their types, constants
and function-pointer types. Nothing hides behind a conditional: the only
preprocessor conditionals in those four files are the include guards and the
`LUA_USER_H` hook typedef, so all 149 reach the translation and each one is an
entry point a loaded provider has to answer for.

## 2. The typed surface

The typed surface exists to add what a C header cannot express: an owned state
that opens once and closes once, an error set for a call that failed instead of
longjmp-ing out of the process, strings that carry a length instead of a NUL,
and one documented answer to how a C function finds its arguments. Nothing is
reimplemented: every answer comes from the C under `src/`, reached through
`c`.

### The names

| Declaration | What it is |
|---|---|
| `c` | the raw translated route, unchanged |
| `runtime_loaded` | `true` in a `-Druntime=true` build, `false` otherwise |
| `LoadSource`, `LoadError` | the two public runtime types, identical in both configurations |
| `load(source)`, `loadedSource()` | fill and inspect the provider table; see § 4 |
| `State` | an owned `lua_State`: `init`, `initWithAllocator`, `deinit`, `allocator`, `setAllocator` |
| `Thread` | a coroutine the state owns: a `raw: ?*c.lua_State` field plus `resume`, `status`, `errorMessage` |
| `Library` | one of `base`, `package`, `table`, `io`, `os`, `string`, `math`, `debug`, `bit`, `jit`, `ffi`, `string_buffer`; `globalNames`, `open` |
| `Args` | the argument view a C function Lua is calling gets: a `state` pointer and a `base` index, plus `checkStack`, `checkInteger`, `optInteger`, `checkNumber`, `optNumber`, `checkString`, `optString`, `checkType`, `checkAny`, `argError`, `typeError` |
| `Buffer` | a `luaL_Buffer`: `init`, `add`, `push` |
| `jit` | `engine`, `func`, `all_functions`, `all_subroutines`, `trace`, `on`, `off`, `flush`, and `setMode`, `setEngine`, `enable`, `disable`, `flushEngine`, `flushTrace`, `profileStart`, `profileStop`, `profileDumpStack` |
| `Borrowed` | `{ ptr, len }` for a string the state owns: `slice`, `eql`, `copy`, `dup` |
| `RunError` | `RuntimeError`, `SyntaxError`, `MemoryError`, `ErrorInErrorHandler`, `FileError`, `UnexpectedStatus` |
| `State.InitError` | `OutOfMemory`, and nothing else |
| `Number`, `Integer`, `Index` | `c.lua_Number`, `c.lua_Integer`, `c_int` |
| `AllocatorPair` | `{ function, user_data }`: C's `lua_Alloc` callback and the pointer it is handed, as one nominal type. What `State.allocator` reads back and what `State.setAllocator` installs |
| `multret`, `min_c_stack` | `LUA_MULTRET`, `LUA_MINSTACK` |
| `lua_version`, `luajit_version` | `LUA_VERSION` (`"Lua 5.1"`) and `LUAJIT_VERSION` (`"LuaJIT 2.1.1788856981"`) |

`State` carries the rest: stack (`top`, `setTop`, `absoluteIndex`, `pop`,
`pushNil`, `pushValue`, `pushBoolean`, `pushInteger`, `pushNumber`,
`pushString`, `pushLightUserData`, `pushCFunction`, `pushCClosure`),
inspection (`typeOf`, `typeName`, `isNone` … `isUserdata`, `toBoolean`,
`toNumber`, `toNumberX`, `toInteger`, `toIntegerX`, `toString`, `lengthOf`,
`toPointer`, `equal`, `rawEqual`, `nextIsValid`), tables (`newTable`,
createTable`, `getField`, `setField`, `rawGetI`, `rawSetI`, `getGlobal`,
setGlobal`, `concat`), the registry (`pushRegistry`, `ref`, `unref`),
libraries (`openLibs`, `openFfi`, `openStringBuffer`), evaluation (`load`,
`loadFile`, `call`, `protectedCall`, `run`, `errorMessage`, `raise`), the
collector (`collect`, `stepCollection`, `isCollecting`, `countKilobytes`,
`countBytesRemainder`, `bytesInUse`, `setPause`, `setStepMultiplier`) and
coroutines (`newThread`, `isYieldable`).

### The shortest sequence that uses it

```zig
const std = @import("std");
const luajit = @import("luajit");

pub fn main() !void {
    var state = try luajit.State.init();
    defer state.deinit();
    state.openLibs();

    try state.run("return 6 * 7", "inline");
    std.debug.print("{d}\n", .{state.toInteger(1)});
}
```

`State.run` loads a chunk and calls it under a protected call, so a chunk that
raises leaves a readable message on the stack instead of unwinding through
Zig. `run("return 42", null)` leaves one number at index 1.

### Allocation

`State.init` opens through `luaL_newstate` (`src/lauxlib.h:70`), which supplies
the library's internal allocator sentinel (`src/lib_aux.c:373-377`,
`src/lj_state.h:36`); `lua_newstate` answers that with its own pooled
allocator (`src/lj_state.c:262-267`) and installs the panic handler and the
VM-event hook (`src/lib_aux.c:378-386`). **The caller owns nothing and pairs
nothing.** `init` is deliberately not `initWithAllocator(null, null)`: `lua_newstate`
calls the callback it was handed to allocate the state itself
(`src/lj_state.c:269`) and the collector calls it for every block
(`src/lj_gc.c:873`), so a null callback is a call through a null pointer.

`State.initWithAllocator` is the other door. Its callback obeys `src/lua.h:67`:
`osize` describes the block at `ptr`, `nsize` describes the block to return,
and `osize == 0 && nsize == 0` is the **only** request to release. The callback
and the `user_data` are the caller's from then until `deinit`.

`AllocatorPair` is that pair as one nominal type — `{ function, user_data }` —
so what `State.allocator` reads back out of the library and what
`State.setAllocator` installs cannot be two structurally identical anonymous
types. It is read back with `lua_getallocf` rather than remembered, because the
library is the only place that knows.

Three rules that follow, and each one is a place a caller can get it wrong:

* `setAllocator` returns the pair it replaced and **frees nothing**
  (`src/lj_api.c:1297-1302`). Everything the state has allocated so far is
  still outstanding under the old allocator while the next allocation already
  goes to the new one. Put the pair back before `deinit`, because `lua_close`
  releases what is left through the allocator installed *at that moment*
  (`src/lj_state.c:243`), not the one the state was opened with.
* Swapping the library's own allocator away and back also loses its pool:
  `lua_close` destroys that pool only while the installed callback is still
  the one the library installed (`src/lj_state.c:238-243`). The pair
  `allocator` reported at the start is the pair to restore.
* Which pair is installed can change between `init` and `deinit`. The rule is
  the same on both ends: blocks are released by whichever callback is installed
  when the release happens.

### Numbers

**Every Lua number in this SDK is an `f64`.** `Number` is `lua_Number` and
`LUA_NUMBER` is `double` (`src/luaconf.h:118-119`), so `Number` is `f64` on
every target without exception. LuaJIT keeps numbers as doubles and lets the
trace compiler narrow them; a value that has become a number has been an
`f64`, whatever the target is.

**`Integer` is `lua_Integer`, and `lua_Integer` is `ptrdiff_t`**
(`src/luaconf.h:106`). That makes it *the target's scalar*: 64 bits on a
64-bit target and 32 bits on a 32-bit one. It is **not** one width across the
supported targets, and a value written for one pointer width is not portable to
another.

Neither of those is a precision guarantee, and this is the boundary a consumer
is most likely to get wrong. `Integer` is the width LuaJIT will *hold* an
integer in; it says nothing about whether the value that reaches it was ever
exact:

* **An integer stays exact only when it went in as one.** `pushInteger` is how
  an exact 64-bit integer reaches a script, and `toIntegerX` returns it
  unchanged.
* **A string that reads as a number is scanned as a number first.**
  `lua_tointegerx` (`src/lj_api.c:422-445`) calls `lj_strscan_number` on a
  string, and that scanner produces a `lua_Number` (`src/lj_strscan.c:526-529`);
  it only reports `STRSCAN_INT` when the *double it already computed* converts
  back to an integer exactly. `src/lj_api.c:437-440` then returns that integer,
  and `src/lj_api.c:443-444` casts the double when it does not. So the
  `tvisint` branch is reachable, but only for a value the double could already
  represent.
* **The observed consequence.** The decimal string `9007199254740993` — 2^53+1,
  which no `double` holds — comes back as `9007199254740992`. The low bit was
  lost in the scan, before any integer was produced. That is the pinned
  library's own behaviour and this boundary is stated rather than smoothed
  over: the run that observed it is in
  [`README.md`](README.md#the-two-failures-that-are-not-crashes), and it is not
  a facade defect. An SDK assertion that expected the exact value is wrong
  against Lua 5.1, and the fix is the assertion, not the library.

* **A fraction is not refused.** `toIntegerX` casts (`src/lj_obj.h:1010`), so
  `"3.5"` answers `3`, not null. `toNumberX` and `toIntegerX` differ in kind:
  `toString` converts the stack slot in place (`src/lj_api.c:517-522`) and the
  two `X` forms have no such effect and answer `null` instead.

`Number` and `Integer` are two distinct types, so a conversion between them is
visible in a signature; `toIntegerX` and `toNumberX` exist because Lua *does*
convert, and their `?` is the difference between a conversion and a refusal.

### Calling a function

`call` and `protectedCall` take **an argument count and a result count, and no
index**. That is not a simplification, it is the C signature: `lua_call` and
`lua_pcall` (`src/lua.h:202-203`) take neither, and `api_call_base` answers
`L->top - nargs` (`src/lj_api.c:1100-1110`, `:1120-1135`). The stack
arrangement is therefore fixed: **push the function, then its arguments, in
that order.** `result_count` is a count, or `multret` to keep every result,
and neither call returns anything — the results are on the stack.

`call` is the unprotected `lua_call`, so an error inside it unwinds the Lua
stack with a `longjmp` and skips any Zig frame in between. It is correct only
when the caller has no state to lose; `protectedCall` is what a caller normally
wants.

`run(source, chunk_name)` is `load` followed by `protectedCall(0, multret)`,
which is what `luaL_dostring` does (`src/lauxlib.h:115-116`). **Where the
results land follows from that:** `load` pushes the chunk on top of whatever
was already there, and the call takes the function at `L->top - 0`, so the
results land in the slot the loaded chunk occupied. On an empty stack
`run("return 42", null)` leaves one number at index 1; on a non-empty stack the
same value lands where the chunk was, at the top, with everything already there
still below it. A failure lands the same way — the protected frame unwinds to
the caller's own base (`src/lj_err.c:152-164`) and pushes the message where the
function was — so `errorMessage` reads it from the top.

Two consequences a caller has to design around:

* Nothing resets the stack between calls. Call `setTop(0)` first when absolute
  indices are meant to mean something absolute.
* **Anything pushed before `run` is below the loaded chunk, not an argument to
  it**, because `protectedCall(0, …)` passes zero arguments. To pass a value
  into a chunk, `load` it and then `protectedCall(n, …)`.

### A C function's arguments

`Args` is the view a function Lua is calling gets. It is `{ state, base }`,
and **`base` is `1`** for that function: the frame Lua is calling holds that
call's arguments and nothing else, so argument `n` is stack index
`base + n - 1`.

```zig
fn doubleArgument(l: ?*luajit.c.lua_State) callconv(.c) luajit.Index {
    var state = luajit.State{ .raw = l };
    const args = luajit.Args{ .state = &state, .base = 1 };
    state.pushInteger(args.checkInteger(1) * 2);
    return 1;
}
```

`base` is a field rather than a fixed 1 because the same frame can be reached
under a different index — a coroutine's stack, or a value found by an API
search — and a hard-coded 1 would be wrong there. The `State` in that example
**borrows**: `raw` is the pointer Lua handed the function, the wrapper must be
declared `var`, and it must not be `deinit`ed. Every `check*` that fails raises
through `lj_err_argt`/`lj_err_arg` (`src/lj_api.c:245-255`, `:447-464`,
`:512-529`), and that raise is a `longjmp` — correct here and only here,
because Lua called this function and there is a handler above it. The same
call from a plain Zig function skips the frame instead of unwinding it.

### The collector

`collect` is synchronous and complete: after it returns, everything unreachable
has been collected and the weak tables have been cleared.

`stepCollection` answers **whether a full cycle just completed** — not whether
there is more work to do, and not whether anything was collected.
`lua_gc(L, LUA_GCSTEP, 0)` (`src/lua.h:232`) drops the threshold to where the
state is and steps until either the step budget runs out or the collector
returns to its pause state (`src/lj_api.c:1263-1272`), and answers `1` only for
the second (`src/lj_gc.c:741-745`). So `false` means "the step budget ran out
first", and a caller that loops until it sees `true` is running complete
cycles; a caller that treats `false` as "finished" stops early.
`isCollecting` is the separate question about what the collector is doing right
now.

`countKilobytes` and `countBytesRemainder` are `LUA_GCCOUNT` and
`LUA_GCCOUNTB` (`src/lua.h:225-226`): the whole kilobytes and the remainder the
library could not express in kilobytes. `bytesInUse` is their sum.

### Threads and lifetimes

One `State` belongs to one thread at a time. It is plain mutable native state
with no lock in it, exactly as in C, and LuaJIT's own API says the same: two
threads may use two states, or one state at two different times, never one
state at two threads at once.

A `Thread` is a `lua_State` the parent owns, sharing its globals, registry and
collector, with no allocator of its own. `Thread.raw` holds the pointer
`lua_newthread` returned **at creation** — it is a field, not a lookup, so it
cannot come back naming a different coroutine. What keeps the coroutine alive
is the copy `newThread` pushed on the parent's stack: drop that slot and
collect, and `Thread.raw` points at freed memory. `resume` is a Zig reserved
word, so the call is spelled `thread.@"resume"(0)`.

Coroutines are still not concurrent: `lua_yield` and `lua_resume` alternate. In
a runtime-loading build the one piece of shared state is the loader's table,
and the loader handles it — `load` is safe from any thread, and every other
call needs the table published first.

`deinit` releases everything at once and is a no-op the second time. Calling it
while a `Thread` or `Buffer` from that state is still in use is a use after
free in C terms, and nothing here can detect it. A `Buffer` must be
initialized *in place* on the variable that stays, because `luaL_buffinit`
stores a pointer to the array inside the struct it was given.

### Two rules the surface holds to

* **No re-derivation.** Where upstream defines a value, the surface passes it
  through unchanged: `LUA_VERSION`, `LUAJIT_VERSION`, `LUA_MULTRET`,
  `LUA_MINSTACK`, the `LUAJIT_MODE_*` constants and the `LUA_*` global names
  all come from the translation, and `Library.globalNames` is built from
  `src/lualib.h`'s own macros rather than from a table written beside them.
* **A narrowed conversion is never silent.** `Number` is `f64` and `Integer` is
  the target's `ptrdiff_t` width, so they are two distinct types and a
  conversion between them is visible in a signature. What the surface does not
  do is promise precision the library cannot deliver: see **Numbers** above.

## 3. The raw route

`luajit.c` is the complete native surface and is not reduced to the functions
the typed helpers happen to call. Anything the headers declare is reachable
through it, including the debug library, the auxiliary library's Lua 5.2
additions, and the generated version symbol.

```zig
const luajit = @import("luajit");

// The translated namespace, exactly as the headers described it.
// `lua_version` does NOT return a string: it returns a pointer to a static
// `lua_Number` holding `LUA_VERSION_NUM` (src/lua.h:351, src/lj_api.c:136-140).
const reported = luajit.c.lua_version(null).*; // 501.0
```

Variadics are the one place a raw C declaration cannot be reproduced literally.
Where upstream declares a variadic function, the translated route gives you
the real C type and you dispatch through a typed function pointer; the surface
does not pretend a variadic can be wrapped in an ordinary Zig function type.

## 4. Runtime loading

`-Druntime=true` selects the loaded configuration. It is **orthogonal to
`-Dlinkage`**: whether the native library is linked or loaded is a separate
question from which artifact is produced.

### What changes in the graph

`runtime/graph.zig` supplies `createModule(b, translate, target, optimize)`, and
`-Druntime=true` is what selects it in place of `translate.createModule()`.
Four modules result:

| Module | What it is |
|---|---|
| `rt` | `runtime/loader.zig`, the reusable core, in this repository |
| `library` | `runtime/library.zig`, this SDK's descriptor |
| dispatch | generated by `runtime/generate.zig` from the **real** translation output |
| `sync.c` | compiled into the dispatch with `-DRT_SYNC_PREFIX=luajit_rt` |

A linked build imports `runtime/loader.zig` itself, through
`createCoreModule(b, target, optimize)`, and that is the **only** thing it
takes from it: `LoadSource` and `LoadError` are this SDK's public types and
must be the same types whichever configuration is built. Nothing else in that
module is referenced until a runtime configuration instantiates the loader, so
a linked build pays two declarations and no code.

**The one thing a caller must not do:** link the compiled C archive into a
module that imports the dispatch. The facade's `c` import *is* the dispatch;
if anything else in the graph also references the library, the linker resolves
the symbols statically and the runtime route silently becomes a linked one.

### The API

```zig
pub const LoadSource = union(enum) {
    path: []const u8,    // an explicit file path
    system: []const u8,  // an explicit basename or SONAME
};

pub const LoadError = error{
    EmptySource,
    SourceTooLong,
    UnsupportedTarget,
    OpenFailed,
    MissingSymbol,
    ValidationFailed,
    ProviderMismatch,
    ReentrantLoad,
};

pub fn load(source: LoadSource) LoadError!void;
pub fn loadedSource() ?LoadSource;
```

Those four are on the **facade**, so `luajit.load(.{ .path = … })` is how a
caller reaches them, and `luajit.runtime_loaded` says at comptime which
configuration it is in. `load` on a linked build is a `std.debug.panic` — the
message says the module is not runtime-loaded, rather than silently doing
nothing — and `loadedSource()` on a linked build returns `null`, because a
linked build has no request. That is why `LoadSource` and `LoadError` are
defined as `if (runtime_loaded) c.LoadSource else rt.LoadSource`: the types are
this SDK's in both configurations, so a caller can name them without asking
which build it linked against.

* `.path` is passed to the platform loader **unchanged**, and `.system` is
  passed **unchanged** too. There is no path-to-system fallback in either
  direction: choosing between them is the caller's decision, and the loader
  does not second-guess it.
* `load` is safe to call from any thread and any number of times. The same
  request twice succeeds; a **different** request after a success is
  `ProviderMismatch`, and the provider already chosen stays chosen.
* A failed candidate is closed and **nothing is published**. There is no
  automatic retry; an explicit second `load` is the only retry.
* Contending callers wait on the attempt in flight and receive *its* result,
  not a later one's.
* `load` called from a thread already inside a load attempt returns
  `ReentrantLoad` rather than waiting, which is the only answer that is not a
  deadlock.
* `SourceTooLong` refuses rather than truncates: a truncated path is a
  different path, and loading a different file than the one asked for is the
  one outcome this loader must never produce.
* The chosen provider and a copy of its request live to process exit.
* A runtime-loaded build that has not loaded panics **before the first call**,
  in all four optimize modes including `ReleaseFast` and `ReleaseSmall`.

### What a provider must be

Every entry point the four public headers declare, with exactly one exception:

* **`lua_setlevel`** is declared at `src/lua.h:300` and defined nowhere in
  `src/`. LuaJIT does not implement it, so no provider can export it. It is
  listed as optional, which turns a guaranteed `MissingSymbol` on every load
  into a direct `extern` reference that the linker only notices if something
  actually calls it.

Nothing else is excluded. A provider that does not export one of the other
**148** is refused rather than half used.

That **148** is the header's own arithmetic, and it is the same in all four
optimize modes: the four public headers declare **149** entry points, the one no
provider exports, and a C library declaration never joins the required table.
That last part is not automatic — `-Doptimize=ReleaseSafe` turns glibc's
`_FORTIFY_SOURCE` on, and a fortified `<stdio.h>` declares a
`__*_chk`/`__*_alias`/`__*_chk_warn` family that an unfortified one does
not — so `runtime/graph.zig` lists those names as `direct` rather than
routing them to the provider, where nothing exports them.

The strongest entry in that set is the **generated version symbol**. `LUAJIT_VERSION_SYM`
expands to `luaJIT_version_2_1_` followed by the rolling release identifier,
and `genversion.lua` fills that identifier in from `.relver`. For this pin the
provider must export **`luaJIT_version_2_1_1788856981`**. A provider built from
a different rolling snapshot does not export that name and is refused with
`MissingSymbol` before any of its code runs.

### The external ABI families

Resolving the symbols and translating the header is the boundary. It is **not**
proof that a provider is compatible, and nothing here pretends to add one. A
provider must agree with the translated header on:

* **`lua_Number` and `lua_Integer`.** `double` and `ptrdiff_t`
  (`src/luaconf.h:106,119`). `ptrdiff_t` is 32 bits on a 32-bit target and 64
  on a 64-bit one, so `lua_Integer` is not one width across the supported
  targets, and a provider built for another pointer width is not a provider for
  this header.
* **`luaL_Buffer`'s layout.** It is a `lua_State *`, two scalars and a
  `LUAL_BUFFERSIZE` byte array (`src/lauxlib.h:135-140`), where
  `LUAL_BUFFERSIZE` is `BUFSIZ > 16384 ? 8192 : BUFSIZ`
  (`src/luaconf.h:113`). It follows from `BUFSIZ`, so a provider compiled where
  `BUFSIZ` exceeds 16384 has a different struct size. That is upstream's ABI,
  not this fork's, and it is why the translation is given the target's own
  headers rather than a fork-defined `BUFSIZ`.
* **The target's scalar widths and calling conventions**, which is what "the C
  ABI" means for a provider reached through `dlopen`.
* **The architecture.** LuaJIT 2.1 compiles for x86, x64, arm, arm64, ppc,
  mips32 and mips64 and for nothing else — `src/lj_arch.h:51-69` selects one of
  those or fails the build. A wasm32 or riscv64 provider cannot exist.

What is deliberately **not** part of the boundary:

* **`LJ_GC64`.** It is fixed by the architecture (see
  [`README.md`](README.md#boundaries-a-consumer-must-not-cross)) and changes
  `GCobj` and `GCRef` *inside* the library. Nothing in the four public headers
  depends on it, so a provider built either way presents the same declarations
  and this route cannot tell them apart. A caller that cares reads `jit.arch`
  or `jit.os` from Lua, not the collector's mode.
* **Which JIT back end** the provider was built with. `jit.on`/`jit.off` and
  trace flushes behave the same through the same entry points.
* **Whether FFI was compiled in.** `LJ_HASFFI` decides whether
  `require "ffi"` succeeds, and that is a property of the provider a caller
  discovers by using it, not something the loader can check without a state and
  a `require`.

### The one check that runs

`runtime/library.zig` adds exactly one validation, after every symbol has
resolved and before anything is published: it creates a state through
`luaL_newstate()`, reads what `lua_version()` reports, and closes the state
again.

`lua_version()` returns `const lua_Number *` — a pointer to a static `double`
holding `LUA_VERSION_NUM` (`src/lua.h:351`, `src/lj_api.c:136-140`), **not** a
string. The check therefore compares the pointed-to value, and it reads
`LUA_VERSION_NUM` from the translation rather than restating `501`, so it
cannot drift from the header this build selected.

That proves the library loaded, allocated a state, and identifies itself as Lua
5.1 rather than as some other Lua release whose declarations happen to have the
same names: PUC-Rio's Lua 5.5 answers `505.0` and is refused **by value**, not
by symbol count. It does not prove the collector mode, the number mode, the
architecture or the `luaL_Buffer` size.

### Isolation between SDKs

`runtime/sync.c` is compiled with `-DRT_SYNC_PREFIX=luajit_rt`, and
`runtime/library.zig` binds exactly those five names. Two spellings of that
prefix have to agree — the descriptor names them, `runtime/graph.zig` defines
the macro — and a build where they disagree does not link. That is the whole
error report: there is no runtime path that could hide it.

The core never names a symbol of its own, which is what lets two SDKs, or two
configurations of one SDK, hold their own loader state in one process without
sharing any of it.

## 5. How the dispatch is generated

`runtime/generate.zig` runs as a **host program** over the translation step's
real output, so the dispatch describes the header this build actually selected
rather than another one. Nothing is cached across configurations: a different
header configuration produces a different translation step output, which
produces a different dispatch.

The generator reads one list of `pub extern fn` declarations and cannot, by
itself, tell `lua_pushinteger` from `fopen`. Three lists in
`runtime/graph.zig` resolve that:

| List | What it holds |
|---|---|
| `libc_noise` | every `pub extern fn`/`var`/`const` name the pinned Zig 0.16.0 `zig translate-c` produces from this package's aggregate translation unit that is not LuaJIT's own namespace, unioned over every published target — the 53-platform Tier 1/2 table plus the six `check` targets — and read through the front end `build_support/graph.zig:768 routeFor` gives each one |
| `provider_optional` | exactly one name, `lua_setlevel` |
| `provider_excluded` | empty |

That is 502 names, and it is measured rather than asserted: the derivation is
re-runnable with `zig translate-c -lc -target <triple> -Isrc -I<generated>
build_support/translate.h` over each target in the matrix, taking every
`pub extern` name that is not `lua_*`/`luaL_*`/`luaJIT_*`/`lj_*`/`luaopen_*`.
The 149 library-owned names are excluded, so no LuaJIT entry point is listed
here. Adding the measurement is what covered the C libraries an earlier list
missed: the mingw secure-append block (`sec_api/stdio_s.h`,
`corecrt_stdio_config.h`), the Darwin and BSD `<stdio.h>` spellings, the 45
`wasm-wasi-musl/wasi/api.h` entry points WASI's `<stdio.h>` reaches, and the
three stream objects **`stdin`, `stdout` and `stderr`**, which every one of
these libcs declares and which the previous list omitted — so its dispatch
demanded them from the LuaJIT provider at load time.

The libc list is a **union across the libc implementations this SDK targets**,
because the list is compiled into a target-independent build file. A name a
given target's `stdio.h` does not declare simply matches nothing, which is
harmless; a libc name left *out* of the list would be demanded from the
provider at load time and refused, which is not.

`<stdio.h>` is the only C library header these four headers reach, so that list
is complete for them. `assert.h` is the next candidate and is unreachable:
`src/luaconf.h:144-145` includes it only when `LUA_USE_ASSERT` or
`LUA_USE_APICHECK` is defined, and neither is.

## 6. Verification status

**Parts of this SDK have been built. No gate is recorded as passing.** The full
table is [`README.md`](README.md#3-build-run-and-test-matrix); this section adds
only what is specific to the Zig surface and the runtime route.

* **The facade, the tests, the smoke example and the consumer compile and
  link** in the linked configuration. Reaching that took exactly one missing
  link dependency, named in [`README.md`](README.md#3-build-run-and-test-matrix)
  and specified in [`UPSTREAM.md`](UPSTREAM.md#link-dependencies): the external
  unwinder upstream's `LUAJIT_UNWIND_EXTERNAL` declares.
* **`zig build test`, Debug, the last recorded run: 29 tests, 5 pass, 2 fail,
  22 crashed.** All 22 crashes are one upstream source pattern reached through
  `openLibs`, not 22 defects; the narrow compiler flag that addresses it has
  **not** been re-run since. The two failures that are not crashes are in
  [`README.md`](README.md#the-two-failures-that-are-not-crashes): one is Lua
  5.1's own `double` boundary described under **Numbers** above, and one is
  recorded as an open item whose cause was not re-established.
* **`-Druntime=true` is declared and wired but has never been run.** The
  dispatch is generated from the real translation output, the descriptor and
  the loader core are in the tree, and the substitution is one `if` in
  `build_support/graph.zig` — which is a statement about the source, not a
  gate result. Every row below that names the runtime route is therefore
  unobserved, including the panic-before-first-call behaviour.

| Gate | Status |
|---|---|
| `zig build` | `PENDING-VERIFICATION` |
| `zig build test` in Debug and ReleaseSafe | `OBSERVED-FAIL` in Debug before the sanitizer flag landed (29 tests: 5 pass, 2 fail, 22 crashed); `PENDING-VERIFICATION` after it, and in ReleaseSafe |
| `zig build smoke` | `PENDING-VERIFICATION` — compiled, not recorded as run |
| `zig build check`, six compile-only targets | `PENDING-VERIFICATION` |
| `zig build consumer` | `OBSERVED-PASS` — nine nested cases in Debug: both linkages, linked and runtime-loaded, default and explicit target, plus the refusal case |
| `zig build consumer` on a foreign target with no enabled executor | `PENDING-VERIFICATION` — the install-only branch (`CHANGELOG.md` § 25) is source-confirmed and has not been run |
| `zig build -Druntime=true` and its consumers | `PENDING-VERIFICATION` — declared, wired, never run |
| Load-failure, retry, idempotence, provider-change and release-mode panic behaviour | `PENDING-VERIFICATION` |
| Cross-target matrix | `PENDING-VERIFICATION` |
| Installed C consumer, fetched Zig consumer | `PENDING-VERIFICATION` |

No receipt predates this SDK's own first run: unlike the SDKs that predate
this migration, LuaJIT inherited none, and it has no recorded failure beyond
that run. What exists above is this tree's first run, and it failed. The driver
probes of epoch `20261004T213021Z` and the nested-delivery epoch
`20261004T220323250122Z` are in
[`README.md`](README.md#what-has-actually-been-observed). Both are about the
native and installed tree. The second one runs `consumer/src/main.zig` against
the installed dependency, which is the dependent-package route and not a row of
this table.

A test in this SDK must be an **independent known answer** or an
interoperability check — the kind of thing that could fail if the library were
wrong. Nothing here asserts that a version string is what it claims to be,
that a symbol exists, or that two calls into this build agree with each other;
those belong to [`UPSTREAM.sha256`](UPSTREAM.sha256) and to the driver's gates.

## See also

* [`README.md`](README.md) — the native source, the native build, the gate
  table, consumption
* [`UPSTREAM.md`](UPSTREAM.md) — the pin, the closure, the generated inputs, the
  ABI facts
* [`FORK-NOTES.md`](FORK-NOTES.md) — the decisions behind each of these, with
  their boundaries
* [`NOTICE.md`](NOTICE.md) — the per-file licence audit