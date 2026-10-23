# Zig facade API

This file covers the typed facade. Package consumption and build options are in
`README.md`.

## Module exports

- `c`: the four translated public headers. Facade types use these declarations.
- `runtime_loaded`: comptime `bool`; true when calls use a loaded library.
- `LoadSource`: `union(enum) { path: []const u8, system: []const u8 }`.
  `.path` names a file; `.system` names a platform-loader entry.
- `LoadError`: `EmptySource`, `SourceTooLong`, `UnsupportedTarget`,
  `OpenFailed`, `MissingSymbol`, `ValidationFailed`, `ProviderMismatch`,
  `ReentrantLoad`.
- `load(source)`: `LoadError!void`.
- `loadedSource()`: the successful request, or `null` if none exists.
- `Number`, `Integer`, `Index`: `c.lua_Number`, `c.lua_Integer`, `c_int`.
- `lua_version`, `luajit_version`: NUL-terminated strings from the headers.
- `multret`, `min_c_stack`: translated `LUA_MULTRET` and `LUA_MINSTACK`.
- `RunError`: `RuntimeError`, `SyntaxError`, `MemoryError`,
  `ErrorInErrorHandler`, `FileError`, `UnexpectedStatus`.

In a runtime build, call `load` before any native call; calls before it panic.
The same successful request may be repeated; a different request returns
`ProviderMismatch`. A failed attempt publishes nothing and can be retried
explicitly. The provider handle and request live until process exit. There is no
fallback or unload. Concurrent callers wait for the active attempt; a recursive
call returns `ReentrantLoad`. In a linked build, `load` panics and
`loadedSource()` is `null`.

Every declared LuaJIT entry point is required except `lua_setlevel`, which
upstream declares but does not implement. This pin also requires the generated
`luaJIT_version_2_1_1788856981` symbol. The loader checks the provider's Lua
version after opening a state; it does not validate architecture, numeric
widths, collector mode or `luaL_Buffer` layout.

## State and stack

`State` owns `raw: ?*c.lua_State`. `init()` uses LuaJIT's allocator.
`initWithAllocator(function, user_data)` uses a non-null C `lua_Alloc` callback
and caller-owned context. Both return `State.InitError!State`; `InitError` is
only `OutOfMemory`. Custom blocks need at least eight-byte alignment. Keep the
callback and context valid through `deinit`.

`deinit()` closes the state, nulls `raw` and is a no-op when repeated. It
invalidates every thread, buffer and borrowed value from that state. A state
has no lock and must not be used concurrently from multiple threads.

`allocator()` returns `AllocatorPair { function, user_data }`.
`setAllocator(function, user_data)` returns the previous pair and frees no
blocks. Restore it before `deinit`, which frees remaining blocks through the
installed callback.

`State` methods:

- **Stack:** `top`, `setTop`, `absoluteIndex`, `pop`, `pushNil`, `pushValue`,
  `pushBoolean`, `pushInteger`, `pushNumber`, `pushString`, `pushLightUserData`,
  `pushCFunction`, `pushCClosure`.
- **Type and conversion:** `typeOf`, `typeName`, `isNone`, `isBoolean`,
  `isNumber`, `isString`, `isTable`, `isFunction`, `isThread`, `isUserdata`,
  `toBoolean`, `toNumber`, `toNumberX`, `toInteger`, `toIntegerX`, `toString`,
  `lengthOf`, `toPointer`, `equal`, `rawEqual`, `nextIsValid`.
- **Tables and registry:** `newTable`, `createTable`, `getField`, `setField`,
  `rawGetI`, `rawSetI`, `getGlobal`, `setGlobal`, `concat`, `pushRegistry`,
  `ref`, `unref`.
- **Libraries:** `openLibs`, `openFfi`, `openStringBuffer`.
- **Execution:** `load`, `loadFile`, `call`, `protectedCall`, `run`,
  `errorMessage`, `raise`.
- **Collector:** `collect`, `stepCollection`, `isCollecting`, `countKilobytes`,
  `countBytesRemainder`, `bytesInUse`, `setPause`, `setStepMultiplier`.
- **Coroutines:** `newThread`, `isYieldable`.

`load` and `loadFile` return `RunError!void`.
`protectedCall(nargs, nresults)` returns `RunError!void`; `call` is unprotected
and can longjmp past Zig frames. `run(source, chunk_name)` loads then calls
with zero arguments and `multret`. Results or the error message remain on the
stack; existing values are not cleared. `raise` is `noreturn` and is safe only
beneath Lua's protected-call boundary.

`Library` has `base`, `package`, `table`, `io`, `os`, `string`, `math`, `debug`,
`bit`, `jit`, `ffi`, and `string_buffer`, with `globalNames()` and `open(state)`.
`open()` restores the stack; `openLibs()` opens libraries in upstream order and
preloads `ffi` for `require`, but creates no global `ffi`.
Direct `.package.open` needs a Lua call frame; `openLibs()` supplies one.
`Library.open` for `.ffi` and `.string_buffer` installs no global.
`State.openFfi()` installs global `ffi` and must be called once.
`State.openStringBuffer()` installs `string.buffer` after `string` is open.

## Borrowed values and helpers

`Borrowed { ptr, len }` views a Lua-owned string; it is not NUL-terminated.
It remains valid while its source is reachable and has not been popped,
overwritten or collected. `slice()` views the bytes; `eql(bytes)` compares;
`copy(buffer)` returns `error{NoRoom}![:0]const u8`; `dup(allocator)` copies
into caller-owned memory. `toString(index)` may convert its stack slot in place;
`toNumberX` and `toIntegerX` do not.

LuaJIT stores numbers as `double`, so `Number` is `f64`. `Integer` is target-
width `ptrdiff_t`, not a Lua integer subtype. `2^53 + 1` cannot round-trip as a
number. A fractional `toIntegerX` converts rather than refusing.

`Args { state, base }` reads arguments inside a C function called by Lua.
`base` is argument 1's stack index (normally `1`); argument `n` uses
`base + n - 1`. `checkStack`, `checkInteger`, `optInteger`, `checkNumber`,
`optNumber`, `checkString`, `optString`, `checkType`, `checkAny`, `argError`,
and `typeError` use Lua's argument checks. Failures raise through `longjmp`; use
these helpers only in a Lua-invoked C callback. The wrapped `State` borrows
Lua's pointer and must not be deinitialized.

`Buffer` wraps `luaL_Buffer`. Call `buffer.init(&state)` on the variable that
will remain, append with `buffer.add(bytes)`, then finish with `buffer.push()`.
Do not move or copy it after initialization; `push()` spends the buffer.

`Thread` wraps the coroutine pointer returned by `newThread()`. The parent
state's stack slot keeps it alive. Resume with
`thread.@"resume"(argument_count)`, which returns `RunError!void`; `status()`
and `errorMessage()` inspect it. A yield is not an error.

## JIT controls

`jit` re-exports the translated constants `engine`, `func`, `all_functions`,
`all_subroutines`, `trace`, `on`, `off`, and `flush`.

- `setMode(state, index, mode)` applies a mode and reports success.
- `setEngine(state, mode)`, `enable(state)`, `disable(state)`,
  `flushEngine(state)` and `flushTrace(state, trace_index)` control the engine
  and compiled traces.
- `profileStart(state, mode, callback, data)`, `profileStop(state)` and
  `profileDumpStack(state, format, depth)` control sampling. The callback runs
  on the script's thread and must not call back into that state. The dump is a
  `Borrowed` string.