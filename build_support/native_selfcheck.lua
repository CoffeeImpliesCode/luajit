-- SPDX-License-Identifier: MIT
-- native_selfcheck.lua -- what the *delivered CLI* is, checked by running it.
--
-- This is not a test of the facade. It is the proof that the native delivery is
-- a real LuaJIT rather than a Lua interpreter: that the interpreter loads, that
-- the bytecode compiler and reader round-trip, that the JIT compiles and runs a
-- trace, and that the FFI library is present and callable. A build that had
-- quietly produced an interpreter-only library fails on `jit.on`, and a build
-- that had quietly dropped the FFI fails on the `ffi.cdef` call below.
--
-- Run as: luajit native_selfcheck.lua
--
-- Every expectation is Lua 5.1 semantics or LuaJIT's own documented behaviour,
-- not a number this build produced:
--
--   * `_VERSION` is "Lua 5.1" because `luaconf.h:106` keeps the Lua 5.1 ABI and
--     `lj_arch.h:55-70` selects the x86/x64 backend; LuaJIT's own `luaconf.h`
--     carries no other release string.
--   * `jit.status()` returning true is `lib_jit.c:741-750` reporting that
--     `jit_init` ran; the trace count afterwards is the count
--     `jit.status` reads out of `J->snaplist`, populated by the trace
--     recorder.
--   * `string.dump`/`loadstring` round-trip is `lj_lib.h`'s standard-library
--     pair; a failure there is a bytecode-format defect, not a policy one.
--   * `math.floor(3.7)` is 3 and `tostring(1/3)` is Lua 5.1's `%.14g` format
--     (`luaconf.h:122`).
--
-- The script reports every failure rather than stopping at the first, so one
-- run names every thing that is wrong.

local failures = 0

local function check(what, ok, detail)
  if ok then
    io.write(string.format("ok   %-34s %s\n", what, detail or ""))
  else
    failures = failures + 1
    io.write(string.format("FAIL %-34s %s\n", what, detail or ""))
  end
end

-- 1. The interpreter itself.
check("_VERSION is Lua 5.1", _VERSION == "Lua 5.1", _VERSION)

-- 2. The JIT engine exists and is on. `jit.on` is `lib_jit.c:46-56`; a build
--    with LUAJIT_DISABLE_JIT has no `jit.on` at all, so this is the check that
--    separates LuaJIT from an interpreter.
check("jit table present", type(jit) == "table", type(jit))
check("jit.on exists", type(jit.on) == "function", type(jit.on))
check("jit.version is a string", type(jit.version) == "string", tostring(jit.version))
check("jit.os is reported", type(jit.os) == "string", tostring(jit.os))
check("jit.arch is reported", type(jit.arch) == "string", tostring(jit.arch))

jit.on()

-- 3. The JIT actually compiles a trace.
--    `jit.attach(cb, "trace")` (`lib_jit.c:123-150`, `lj_vmevent.c`) installs a
--    VM-event callback, and `"trace"` is the event being subscribed to, not a
--    value the callback is handed. What the callback is handed is what the
--    event *is*: `lj_trace.c:474-488` pushes `"start"` when a trace's machine
--    code is about to be linked in, `:562-566` pushes `"stop"` when recording
--    finished, and `:626-646` pushes `"abort"` when it did not. Upstream's own
--    reader reads them the same way -- `dump_trace(what, ...)` switches on
--    `"start"`, `"stop"`, `"abort"` and `"flush"` (`src/jit/dump.lua:566-596`).
--    A stopped trace is a compiled trace, so that is what is counted here.
--    `jit.status()` is *not* a trace counter: `lib_jit.c:101-118` returns
--    whether the engine is on plus CPU and optimisation strings, so reading a
--    number out of it would be reading something that is not a count.
local traces = 0
jit.attach(function(what)
  if what == "stop" then
    traces = traces + 1
  end
end, "trace")

check("jit.attach installed", type(jit.attach) == "function", type(jit.attach))

local function fib(n)
  if n < 2 then
    return n
  end
  return fib(n - 1) + fib(n - 2)
end

local fib_result = fib(24)
check("recursive fib(24) is correct", fib_result == 46368, tostring(fib_result))

local sum = 0
for i = 1, 100000 do
  sum = sum + i
end
check("numeric loop sums to 5000050000", sum == 5000050000, tostring(sum))

check("the JIT compiled at least one trace", traces > 0, traces .. " trace event(s)")

-- 3b. `jit.status` reports the engine is on, and reports the CPU flags it found.
--     `lib_jit.c:101-118` pushes a boolean for `JIT_F_ON` and then the CPU and
--     optimisation flag strings.
local on, cpu, opt = jit.status()
check("jit.status reports the engine on", on == true, tostring(on))
check("jit.status reports CPU flags", type(cpu) == "string" and #cpu > 0, tostring(cpu))
check("jit.status reports optimisation flags", type(opt) == "string", tostring(opt))

-- 4. The bytecode compiler and reader round-trip. `string.dump` emits a
--    precompiled chunk (`lib_base.c`'s `string_dump`) and `loadstring` reads it
--    back (`lj_load.c`). A build whose bytecode tables disagreed with its reader
--    fails here rather than at some consumer's load.
local chunk = string.dump(function(x) return x * 3 end)
check("string.dump produced a chunk", #chunk > 0, tostring(#chunk) .. " bytes")
local reloaded = assert(loadstring(chunk))
check("dumped chunk reloads and runs", reloaded(14) == 42, tostring(reloaded(14)))

-- 5. The FFI. `ffi.cdef` declares a C type and `ffi.C.*` calls through it, so
--    a build with LUAJIT_DISABLE_FFI fails on the first line. libm's `sqrt` is
--    declared rather than a Lua-callable name so the call has to go through the
--    FFI's own C-call machinery.
--
--    `ffi` is not a global, and upstream never made it one: `luaL_openlibs`
--    puts exactly one entry into the registry's `_PRELOAD`,
--    `{ LUA_FFILIBNAME, luaopen_ffi }` (`src/lib_init.c:32-37`), which is
--    `package.preload`, so the library is reached by `require` and by nothing
--    else. Reading a global here would call a build that has its FFI perfectly
--    complete a build that has none, and then crash indexing it.
local ok_ffi, ffi = pcall(require, "ffi")
check("ffi library loads", ok_ffi and type(ffi) == "table",
      ok_ffi and type(ffi) or "require failed")
if ok_ffi then
  ffi.cdef[[ double sqrt(double); ]]
  check("ffi calls libm sqrt", ffi.C.sqrt(16.0) == 4.0, tostring(ffi.C.sqrt(16.0)))
end

-- 6. Lua 5.1 numeric formatting and the string library, which are the parts a
--    facade most often gets wrong by substituting a different runtime.
check("tostring formats like %.14g", tostring(1 / 3) == "0.33333333333333", tostring(1 / 3))
check("math.floor truncates", math.floor(3.7) == 3, tostring(math.floor(3.7)))
check("string.format %d works", string.format("%d", 42) == "42", string.format("%d", 42))
check("table.concat works", table.concat({ "a", "b", "c" }, "-") == "a-b-c",
      table.concat({ "a", "b", "c" }, "-"))

-- 7. The jit.* Lua modules. Upstream installs these under `share/luajit-2.1/jit`
--    (`Makefile:45`, `:99-104`) and the CLI finds them through `LUA_LJDIR`
--    (`luaconf.h:52-56`). Requiring them is what proves the *installed* module
--    directory is on the search path, which a library-only gate never touches.
--
--    `jit.bc` is the bytecode-mode module and asserts at load time that its
--    core and library versions agree (`src/host/buildvm.c:352-356` generates
--    that assertion into `jit/vmdef.lua`), so a mismatched pair fails here too.
local ok_vmdef = pcall(require, "jit.vmdef")
check("jit.vmdef loads from the install tree", ok_vmdef,
      ok_vmdef and "loaded" or "not found on LUA_LJDIR")

local ok_bc = pcall(require, "jit.bc")
check("jit.bc loads", ok_bc, ok_bc and "loaded" or "not found")

local ok_dump = pcall(require, "jit.dump")
check("jit.dump loads", ok_dump, ok_dump and "loaded" or "not found")

-- 8. Error handling reaches the pcall boundary, which is how a C error is
--    observed from Lua. Without it a segfault in the VM would look like a
--    missing value rather than a caught error.
local ok_pcall = pcall(function() error("deliberate") end)
check("pcall observes a Lua error", ok_pcall == false)

io.write(string.format("\n%d failure(s)\n", failures))
if failures ~= 0 then
  os.exit(1)
end