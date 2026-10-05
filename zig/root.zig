// SPDX-License-Identifier: MIT
//
//! Zig facade over LuaJIT's own C implementation.
//!
//! No part of the interpreter, the compiler or the FFI is reimplemented here.
//! Every answer this module returns is produced by the C under `src/`, reached
//! through `pub const c`, the module the build produces from this package's
//! one translated header. What the facade adds is the part a C header cannot
//! express: an owned state that can only be opened once and closed once, an
//! error set for a call that failed instead of longjmp-ing out of the process,
//! strings that carry their length instead of a NUL, and one documented answer
//! to how a C function finds its arguments.
//!
//! ## Import routes
//!
//! One Zig route is published: `dep.module("luajit")` in the dependent's
//! `build.zig`, which is `@import("luajit")` in source. The raw translated
//! header is `c` on that same module and is not published as a module of its
//! own, so the declarations and the library that satisfies them arrive through
//! one route. A C consumer takes the installed headers and library instead;
//! `README.zig.md` names that layout.
//!
//! The shortest sequence that uses this module:
//!
//! ```zig
//! const std = @import("std");
//! const luajit = @import("luajit");
//!
//! pub fn main() !void {
//!     var state = try luajit.State.init();
//!     defer state.deinit();
//!     state.openLibs();
//!
//!     try state.run("return 6 * 7", "inline");
//!     std.debug.print("{d}\n", .{state.toInteger(1)});
//! }
//! ```
//!
//! `State.run` is the workhorse: it loads a chunk and calls it under a
//! protected call, and a chunk that raises leaves a readable message on the
//! stack instead of unwinding through Zig. This package is developed and gated
//! against Zig 0.16.0, which is the floor `build.zig.zon` records.
//!
//! ## What this module is not
//!
//! It is a Lua 5.1 surface. LuaJIT implements the Lua 5.1 language and API and
//! adds extensions to it (`src/luajit.h`, the `bit` and `jit` libraries, the
//! FFI, `string.buffer`), and this facade names those extensions where they are
//! callable from C. It makes no claim about PUC-Rio's Lua 5.5: `lua_Number` is
//! `double` and `lua_Integer` is `ptrdiff_t` here (`src/luaconf.h:106` and
//! `src/luaconf.h:119`), which is 5.1's ABI and not 5.5's, and a 5.5 library
//! is not a provider for this header. `runtime/library.zig` states the whole
//! boundary and what is checked about it.
//!
//! ## Two configurations: linked and runtime-loaded
//!
//! This module is built in one of two shapes, and `runtime_loaded` says which
//! at comptime.
//!
//! *Linked* is the default. The library is linked, `c` is the translated
//! header, and every call below is a direct call with no table and no check.
//!
//! *Runtime-loaded* is opt-in (`-Druntime=true`). The library is not linked; `c`
//! is a dispatch generated from the same translation step's output, and every
//! entry point the four public headers declare is resolved through the platform
//! loader when the caller calls
//!
//! ```zig
//! try luajit.load(.{ .path = "/usr/lib/libluajit-5.1.so.2" });
//! ```
//!
//! before using anything else. A call into a module that has not loaded stops
//! the program with a message naming the function, in every optimization mode.
//! That is a programming error rather than a recoverable condition: the table
//! does not exist yet and there is no partial state to fall back on.
//!
//! The provider is reached, never guessed. `.path` names a file and `.system`
//! names a library for the platform loader; neither falls back to the other,
//! there is no unload and no reset, and the module keeps the handle and its own
//! copy of the request to the end of the process.
//!
//! Everything below is identical in both configurations. `State`, `Library`,
//! `Buffer`, `Args`, `Thread` and `jit` are the same types either way, because
//! every type and constant in the dispatch is re-exported from the translation
//! rather than restated.
//!
//! ## Allocation
//!
//! A `State` allocates through the allocator it was opened with, and this
//! module never allocates anything itself. `State.init` opens a state through
//! `luaL_newstate`, so the allocator is LuaJIT's own pooled one
//! (`src/lj_state.c:262-267`); there is nothing for a caller to free and
//! nothing to pair. `State.initWithAllocator` is the other door: it hands LuaJIT
//! an allocator and a user pointer, and both belong to the caller from then
//! until `deinit`.
//! The pairing rule is `src/lua.h:67`: a callback receives `osize` describing
//! the block at `ptr` and `nsize` describing the block it must return, and
//! `osize == 0 && nsize == 0` is the only request to release. That pair is an
//! `AllocatorPair`: this module's name for `lua_Alloc` plus its pointer.
//! `State.allocator` reads it back out of the library rather than remembering
//! it, because the library is the only place that knows. `State.setAllocator`
//! answers the pair it replaced, and `lua_setallocf` swaps the two fields
//! without freeing anything (`src/lj_api.c:1297-1302`), so every block the old
//! allocator handed out stays the old allocator's to release.
//!
//! Which pair is installed can change between `init` and `deinit`, and the
//! rule is the same on both ends: blocks are released by whichever callback is
//! installed at the moment (`src/lj_state.c:243`). A caller that swaps one in
//! has to put the pair back before `deinit`, and that pair is what `setAllocator`
//! handed back.
//!
//! Memory the *script* allocates belongs to the state and is released by
//! `deinit`, whole. A caller who wants it back earlier runs a collection; see
//! `State.collect`.
//!
//! ## Errors
//!
//! Two different failures are represented two different ways, because they are
//! two different things.
//!
//! A chunk that fails is *returned*: `load`, `run` and `protectedCall` answer a
//! `RunError` and leave the message on the stack, where `errorMessage` reads it.
//! This is the only way to call a chunk of unknown code.
//!
//! A C function that fails is *not returned*: `lua_error`, `luaL_error` and the
//! `luaL_argerror`/`luaL_typerror` family unwind the Lua stack with a `longjmp`
//! past the C frame that raised them (`src/lua_api.c` is not the shape; see
//! `src/lj_api.c` `lua_error` and `src/lib_aux.c` `luaL_argerror`). This module
//! therefore never calls one from a Zig frame that is not already inside a
//! protected call, and it says so at every place it hands you one: `Args`
//! functions are for a function that Lua is calling, and `State.raise` must be
//! called with a protected call underneath it. A Zig frame in between does not
//! get unwound by that `longjmp`; it is skipped, which is a use-after-free of
//! anything it owned. `RunError` therefore covers the returned failures only.
//!
//! The typed surface also never calls a C variadic function with arguments.
//! Where a formatted message is wanted it is built in Zig and pushed as one
//! string, so no Lua format string is interpreted on this side of the boundary.
//! `luaL_error`, `lua_pushfstring` and `lua_pushvfstring` are variadic
//! (`src/lua.h:166-168`, `src/lauxlib.h:53`) and are reached through `c`.
//!
//! ## Strings
//!
//! Every string this module hands back is a `Borrowed`: a pointer and a length
//! taken from a Lua string that the state owns. Lua strings are immutable,
//! interned and collected, so a `Borrowed` is valid until the value it came
//! from is popped, overwritten or collected -- not until the end of the call
//! that produced it. Where a caller needs the bytes to outlive that, it copies
//! them, and `Borrowed.copy` does that with an allocator the caller names. No
//! function here hands out a `[*:0]const u8` that Lua would own.
//!
//! `toString` is the one conversion with a side effect: `lua_tolstring`
//! (`src/lua.h:150`) converts the value at that index *in place*, so calling it
//! on a number changes that stack slot to a string. `toNumberX` and
//! `toIntegerX` have no such effect and answer `null` instead.
//!
//! ## Numbers
//!
//! `Number` is `lua_Number` and `Integer` is `lua_Integer`, taken from the
//! translation rather than restated, so they are `f64` and `isize` for a
//! 64-bit target and `f64` and `i32` for a 32-bit one. `ptrdiff_t` is what
//! `src/luaconf.h:106` names and what decides the second width, so a value
//! written for one pointer width is not portable to another.
//!
//! LuaJIT keeps numbers as doubles and lets the trace compiler narrow them, and
//! this build has no integer subtype beside them at all. `LUAJIT_NUMMODE` is
//! not defined, so `LJ_DUALNUM` is 0 (`src/lj_arch.h:575-586`), and `setintV`
//! stores `o->n = (lua_Number)i` rather than a tagged int
//! (`src/lj_obj.h:953-960`). `pushInteger` is that path: `lua_pushinteger` calls
//! `setintptrV` (`src/lj_api.c:632-635`), which on a 64-bit target is
//! `setint64V` (`src/lj_obj.h:970-974`) and stores the double for anything past
//! 32 bits. An exact 64-bit integer therefore does not reach a script exact -
//! `pushInteger(2^53 + 1)` read back answers `2^53`, while `2^53` itself is
//! exact. `Integer` is what the C API converts to, not a value a Lua variable
//! can hold distinctly from the double.
//!
//! A *string* takes the same round trip. `src/lj_strscan.h:28-32` keeps the
//! integer-producing `lj_strscan_number` behind `LJ_DUALNUM`, so the parse at
//! `src/lj_api.c:433` stores a number, the `tvisint( &tmp )` test at `:437` is
//! never reached for a string, and the value reaches `lj_num2int_type` through
//! `lua_Number` at `:441-444`. `toNumberX` is the honest "is this a number at
//! all" test on both sides; neither `toInteger` nor `toIntegerX` refuses a
//! fractional value, and their own documentation says where that answer comes
//! from.
//!
//! ## Threading
//!
//! A `State` belongs to one thread at a time. It is plain mutable native state
//! with no lock in it, exactly as in C, and LuaJIT's own API says the same. Two
//! threads may use two states, or one state at two different times, never one
//! state at two threads at once.
//!
//! Coroutines are different: a `Thread` is a `lua_State` the parent owns, and
//! `Thread.resume` is the only safe way to run one. It is still not concurrent;
//! `lua_yield` and `lua_resume` alternate.
//! `resume` is a Zig reserved word, so the call is spelled
//! `thread.@"resume"(0)` in source.
//!
//! The one piece of shared state in a runtime-loading build is the loader's
//! table, and the loader handles that: it is safe to call `load` from any
//! thread, and every other call needs the table published first.

const std = @import("std");

/// The translated `lua.h`, `lauxlib.h`, `lualib.h` and `luajit.h`, i.e.
/// upstream's ABI exactly as published.
///
/// This is the escape hatch for a caller that needs a declaration this facade
/// does not name -- the debug API, `luaL_gsub`, `lua_dump`, the variadic
/// error functions, the struct fields themselves -- and it is the same module
/// the facade calls, on the same library, so importing the facade is all a
/// dependent needs to reach it. It is not published under a name of its own.
///
/// In a runtime-loading build this module is a generated dispatch instead of
/// the translation step's own output. It publishes the same namespace: every
/// type and constant is re-exported from the translated header rather than
/// restated, so `State`'s `raw` is the same nominal type either way. What
/// differs is how a name reaches the library. In the linked configuration it is
/// a direct call; in the runtime-loaded one it is a call through a table that
/// `load` fills, and a call before that fill stops the program.
pub const c = @import("c");

/// The loader core, which is where a linked build's two public types come from.
///
/// It is imported only by the linked configuration. In a runtime-loading build
/// the dispatch carries its own copy of the same declarations, and this module
/// is never referenced, so it is never resolved and never compiled. Either way
/// there is exactly one `LoadSource` and one `LoadError` in a build, which is
/// what keeps them one type for a consumer that names them.
const rt = @import("rt");

/// Whether this module was configured to resolve its native symbols at run
/// time.
///
/// False for the ordinary build, where the library is linked and `c` is the
/// translated header itself. True when the build generated a dispatch that
/// resolves the same symbols through the platform loader, in which case `load`
/// is the call that makes the library usable.
///
/// It is a comptime constant, so a consumer can write two different code paths
/// and have only the one it chose analyzed.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Which native library `load` should open.
///
/// `.path` is an explicit file path and `.system` is an explicit name for the
/// platform loader. There is no path-to-system fallback and no implicit
/// fallback of any kind; a request that cannot be honoured is an error, not a
/// different library.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Every way `load` can decline.
///
/// Declared here, in the module a consumer imports, rather than only inside the
/// loader: the caller names the failure it is handling.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the native library this module dispatches to.
///
/// In a runtime-loading build this is the whole contract: call it once, then
/// use this module as if it were linked. Calling it again with the same request
/// succeeds and changes nothing; calling it with a different request after a
/// success is `ProviderMismatch`, and the library already in use stays in use.
/// A failed attempt publishes nothing and can be retried explicitly by calling
/// this again: there is no automatic retry, and no implicit second source.
///
/// It keeps the process handle and its own copy of the request to the end of the
/// process. There is no unload and no reset, because the table is
/// process-global state that other code may already have called through.
///
/// Safe to call from any thread. A thread that arrives while an attempt for the
/// same request is in flight waits for that attempt and gets its result,
/// whatever it was. A call from the thread that is running the attempt is
/// `ReentrantLoad` rather than a deadlock.
///
/// In a linked build there is no provider, no table and nothing to resolve, so
/// this stops the program with a message saying so instead of quietly
/// succeeding. `runtime_loaded` is false there, so a consumer that supports both
/// configurations can tell the two apart at comptime instead of meeting this at
/// run time.
pub fn load(source: LoadSource) LoadError!void {
    // The two configurations name different modules, so each is reached only
    // where it exists: a linked build never mentions `c.load`, and a
    // runtime-loaded one never resolves `rt`. The panic below is the linked
    // configuration's whole answer, and it is reached by falling off the end.
    if (comptime runtime_loaded) return c.load(source);
    std.debug.panic(
        "luajit: load was called on a linked build; this module is not " ++
            "runtime-loaded, so there is no library to load. Build with " ++
            "runtime loading configured, or do not call load.",
        .{},
    );
}

/// The request that succeeded, or null when nothing has loaded yet.
///
/// The answer is the loader's own retained copy and stays valid for the life of
/// the process. Null in a linked build, which has no request.
pub fn loadedSource() ?LoadSource {
    if (comptime runtime_loaded) return c.loadedSource();
    return null;
}

/// `lua_Number`, the type a Lua number is (`src/luaconf.h:119`).
///
/// `double` on every target LuaJIT supports. Alias, not a restatement: if a
/// translation ever says something else, this says the same thing.
pub const Number = c.lua_Number;

/// `lua_Integer`, the type an exact integer is (`src/luaconf.h:106`).
///
/// `ptrdiff_t`, so 64 bits on a 64-bit target and 32 on a 32-bit one. See
/// "Numbers" above.
pub const Integer = c.lua_Integer;

/// A Lua stack index, negative counting back from the top.
///
/// `int` in C (`src/lua.h:121-232`), and named here so that an index cannot be
/// passed where a `usize` count is meant.
pub const Index = c_int;

/// `LUA_MULTRET` (`src/lua.h:30`): ask for every value a chunk returned.
pub const multret: Index = c.LUA_MULTRET;

/// `LUA_MINSTACK` (`src/lua.h:88`): the stack space a C function may assume
/// without asking.
pub const min_c_stack: usize = c.LUA_MINSTACK;

/// The version string this build's header carries (`src/lua.h:19-21`).
///
/// `Lua 5.1`, which is what LuaJIT reports and what makes this a 5.1 ABI.
pub const lua_version: [:0]const u8 = c.LUA_VERSION;

/// The LuaJIT version string the generated `src/luajit.h` carries
/// (`src/luajit_rolling.h:33`, with the rolling identifier substituted).
///
/// Read from the translation rather than written here, so it names the build
/// that is actually loaded. A script reaches the same string as `jit.version`.
pub const luajit_version: [:0]const u8 = c.LUAJIT_VERSION;

/// A string a `lua_State` owns.
///
/// Lua strings are immutable and live until the collector reclaims them, which
/// is why nothing here returns a bare `[]const u8` with no lifetime attached.
/// See "Strings" in the module documentation for when this is still valid.
pub const Borrowed = struct {
    ptr: [*]const u8,
    len: usize,

    /// The bytes, without a NUL and without a copy.
    pub fn slice(self: Borrowed) []const u8 {
        return self.ptr[0..self.len];
    }

    /// Whether these are the given bytes. Length first, then contents.
    pub fn eql(self: Borrowed, other: []const u8) bool {
        return std.mem.eql(u8, self.slice(), other);
    }

    /// The bytes as a NUL-terminated string, for the many C entry points that
    /// take one.
    ///
    /// The terminator is written into `buffer`, so the result is only valid
    /// while `buffer` is; it is a copy, never Lua's own bytes.
    pub fn copy(self: Borrowed, buffer: []u8) error{NoRoom}![:0]const u8 {
        if (self.len >= buffer.len) return error.NoRoom;
        @memcpy(buffer[0..self.len], self.ptr[0..self.len]);
        buffer[self.len] = 0;
        return buffer[0..self.len :0];
    }

    /// The bytes copied into memory the caller owns for good.
    pub fn dup(self: Borrowed, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return allocator.dupe(u8, self.slice());
    }
};

/// The allocator a `lua_State` is using: C's callback and the pointer it gets.
///
/// The pair of `src/lua.h:67` as a value, so what `State.allocator` reads back
/// and what `State.setAllocator` installs are one nominal type rather than two
/// structurally identical anonymous ones. This is C's callback, not
/// `std.mem.Allocator`: it is a function pointer taking two pointers and two
/// `size_t`s, and only the state calls it.
///
/// `function` is null only in a pair a caller installed itself. A state opened
/// by `init` reports the library's own pooled allocator, because
/// `lua_getallocf` answers whatever `lua_newstate` stored (`src/lj_api.c:1290-1295`)
/// and `lua_newstate` has no null callback to store: it calls the one it was
/// given before it can store it (`src/lj_state.c:269`).
pub const AllocatorPair = struct {
    /// The callback the library calls for every block it takes and gives back.
    function: c.lua_Alloc,
    /// The pointer handed back to `function` unchanged: the caller's own.
    user_data: ?*anyopaque,
};

/// Why a chunk did not run.
///
/// The names are Lua 5.1's own status codes (`src/lua.h:43-48`, plus
/// `LUA_ERRFILE` from `src/lauxlib.h:19`), translated one for one. There is no
/// invented "out of memory in the facade" case: the library's allocation
/// failure is `MemoryError`, and the only other failures are the ones below.
///
/// `UnexpectedStatus` is the honest remainder. These four headers define six
/// codes and this switch maps five of them; a provider that answered with
/// something else is reported as itself rather than folded into a code it did
/// not return.
pub const RunError = error{
    /// `LUA_ERRRUN`: the chunk raised, or called `error`.
    RuntimeError,
    /// `LUA_ERRSYNTAX`: the chunk did not parse.
    SyntaxError,
    /// `LUA_ERRMEM`: the library could not allocate.
    MemoryError,
    /// `LUA_ERRERR`: the error handler itself failed.
    ErrorInErrorHandler,
    /// `LUA_ERRFILE`: a chunk could not be read. Only `loadFile` can return it.
    FileError,
    /// A status code these headers do not define.
    UnexpectedStatus,
};

/// Map one `lua_load`/`lua_pcall` status onto `RunError`.
///
/// Written once, from the header's own codes, rather than at each call site:
/// three call sites mapping the same six numbers three times is three chances to
/// disagree.
fn runError(status: Index) RunError {
    return switch (status) {
        c.LUA_ERRRUN => error.RuntimeError,
        c.LUA_ERRSYNTAX => error.SyntaxError,
        c.LUA_ERRMEM => error.MemoryError,
        c.LUA_ERRERR => error.ErrorInErrorHandler,
        c.LUA_ERRFILE => error.FileError,
        else => error.UnexpectedStatus,
    };
}

/// One of the standard libraries, by the name `src/lualib.h` gives it.
///
/// `Library.open` calls the matching `luaopen_*` and leaves the stack as it
/// found it, which is what `luaL_openlib` does with the result of the call
/// (`src/lib_aux.c`). For the two libraries upstream installs no global for,
/// this discards the table they return; the dedicated functions below keep it.
pub const Library = enum {
    /// `_G` and `coroutine`. `luaopen_base` returns two values, not one
    /// (`src/lib_base.c:698-708`), and neither is left behind.
    base,
    package,
    table,
    io,
    os,
    string,
    math,
    debug,
    /// LuaJIT's `bit` library. PUC-Rio's Lua 5.1 has no such library.
    bit,
    /// LuaJIT's `jit` control library (`src/lib_jit.c`).
    jit,
    /// The FFI. Upstream registers **no** global for it (`src/lib_ffi.c:855`) and
    /// `luaL_openlibs` only preloads it for `require` (`src/lib_init.c:32-36`).
    /// See `State.openFfi`.
    ffi,
    /// The `string.buffer` extension, the same way: upstream registers no
    /// global for it. See `State.openStringBuffer`.
    string_buffer,

    /// The globals this library installs, in the order `luaopen_*` makes them.
    ///
    /// Empty for the libraries upstream opens no global for. The names come from
    /// the macros in `src/lualib.h:13-23` and from what each `luaopen_*` does,
    /// not from a table written here, so the two cannot drift apart.
    ///
    /// `base` is the one that answers with two: `luaopen_base` creates `_G` and
    /// then registers `coroutine` (`src/lib_base.c:702-706`). `ffi` and
    /// `string_buffer` answer with none, because upstream registers no global
    /// for either (`src/lib_ffi.c:855`).
    pub fn globalNames(self: Library) []const []const u8 {
        return switch (self) {
            .base => &.{ "_G", c.LUA_COLIBNAME },
            .package => &.{c.LUA_LOADLIBNAME},
            .table => &.{c.LUA_TABLIBNAME},
            .io => &.{c.LUA_IOLIBNAME},
            .os => &.{c.LUA_OSLIBNAME},
            .string => &.{c.LUA_STRLIBNAME},
            .math => &.{c.LUA_MATHLIBNAME},
            .debug => &.{c.LUA_DBLIBNAME},
            .bit => &.{c.LUA_BITLIBNAME},
            .jit => &.{c.LUA_JITLIBNAME},
            .ffi => &[_][]const u8{},
            .string_buffer => &[_][]const u8{},
        };
    }

    /// Open this one library.
    ///
    /// The stack is restored afterwards, whatever the library pushed. For the
    /// libraries with a global, that global is now set; for `ffi` and
    /// `string_buffer`, the library's own side effects have happened but the
    /// table it returned is gone, so a caller that wants it uses
    /// `State.openFfi` or `State.openStringBuffer`.
    ///
    /// Order matters between some of them, because they register into each
    /// other: `base` installs `_G` and `coroutine` in one call, and `package`
    /// and `ffi` expect parts of that. `State.openLibs` opens them in the order
    /// upstream uses (`src/lib_init.c:19-30`), which is the order to copy.
    ///
    /// `.package` is the one that cannot be called this way. `luaopen_package`
    /// ends by copying the table it just registered into `LUA_ENVIRONINDEX`
    /// (`src/lib_package.c:601`), and `copy_slot` accepts that index only when
    /// the current frame is a Lua function
    /// (`src/lj_api.c:187-193`); with no Lua call in progress it raises
    /// `LJ_ERR_NOENV`, which from a direct C call means a panic rather than a
    /// return value. That is a different rule from `getcurrenv`
    /// (`src/lj_api.c:89-93`), which falls back to `L->env` and so is happy
    /// outside a frame. The routes that do work are `State.openLibs`, which is
    /// upstream's own `luaL_openlibs` and reaches every opener with a frame -
    /// it pushes each one and calls it (`src/lib_init.c:39-47`) - and calling
    /// this function from inside a call that is itself running on the stack.
    /// `require "package"` is not one of them: `require` and the searchers are
    /// what this library installs, so they are not there to be asked yet.
    pub fn open(self: Library, state: *State) void {
        const top = state.top();
        switch (self) {
            .base => _ = c.luaopen_base(state.raw),
            .package => _ = c.luaopen_package(state.raw),
            .table => _ = c.luaopen_table(state.raw),
            .io => _ = c.luaopen_io(state.raw),
            .os => _ = c.luaopen_os(state.raw),
            .string => _ = c.luaopen_string(state.raw),
            .math => _ = c.luaopen_math(state.raw),
            .debug => _ = c.luaopen_debug(state.raw),
            .bit => _ = c.luaopen_bit(state.raw),
            .jit => _ = c.luaopen_jit(state.raw),
            .ffi => _ = c.luaopen_ffi(state.raw),
            .string_buffer => _ = c.luaopen_string_buffer(state.raw),
        }
        state.setTop(top);
    }
};

/// An owned `lua_State`.
///
/// The one thing here that a C pointer is not: it can be opened once, closed
/// once, and cannot be closed twice by accident, because `deinit` clears it and
/// a second call would have nothing to close. Everything else about the
/// lifetime is Lua's: a state owns its stack, its string interning, its
/// registry and every byte a script allocated, and `deinit` releases all of it
/// at once.
///
/// ## A state this module did not open
///
/// `raw` is a public field, so a C function that Lua called can wrap the
/// pointer it was handed: `State{ .raw = l }`. That wrapper borrows. It must not
/// `deinit` -- the owner is whoever created the state -- and it is only valid
/// for the duration of that call. It exists so `Args` has something to read
/// through; it is not a second owner.
pub const State = struct {
    /// The library's own pointer, or null after `deinit`.
    ///
    /// `lua_State` is an incomplete type in these headers (`src/lua.h:51`), so
    /// nothing outside this module can make one, and nothing can reach the
    /// fields a complete type would have had.
    raw: ?*c.lua_State,

    /// Open a state on LuaJIT's own allocator.
    ///
    /// This is `luaL_newstate` (`src/lauxlib.h:70`), the only native entry point
    /// that supplies a default: it hands `lua_newstate` the library's internal
    /// sentinel (`src/lib_aux.c:373-377`, `src/lj_state.h:36`), which
    /// `lua_newstate` answers with its own pooled allocator
    /// (`src/lj_state.c:262-267`), and it installs the panic handler and the
    /// VM-event hook (`src/lib_aux.c:378-386`). A caller has nothing to free:
    /// `deinit` releases everything.
    ///
    /// It is deliberately not `initWithAllocator(null, null)`. `lua_newstate`
    /// calls the callback it was handed to allocate the state itself
    /// (`src/lj_state.c:269`) and the collector calls it for every block
    /// (`src/lj_gc.c:873`), so a null callback is a call through a null
    /// pointer -- or, on a 64-bit non-GC64 target, the stub that prints
    /// `Must use luaL_newstate() for 64 bit target` and answers null
    /// (`src/lib_aux.c:391-398`). `initWithAllocator` is how a caller owns the
    /// memory instead.
    pub fn init() InitError!State {
        const state = c.luaL_newstate() orelse return error.OutOfMemory;
        return .{ .raw = state };
    }

    /// Open a state whose every allocation goes through `allocator_function`.
    ///
    /// `user_data` is handed back unchanged on every call, which is how the
    /// allocator finds whatever it needs; it is the caller's pointer and stays
    /// the caller's, valid until `deinit` returns. See "Allocation" in the
    /// module documentation for the callback's contract.
    ///
    /// `allocator_function` must not be null: `lua_newstate` calls it to
    /// allocate the state itself (`src/lj_state.c:269`) and the collector calls
    /// it for every block afterwards (`src/lj_gc.c:873`). `init` is how a state
    /// is opened on the library's own allocator instead.
    ///
    /// The `user_data` you give here is the same pointer every call receives, so
    /// an allocator that needs two words of context should take a pointer to
    /// them rather than the two themselves.
    ///
    /// The blocks your allocator returns have to be aligned for what LuaJIT
    /// puts in them. A `TValue` is declared `LJ_ALIGN(8)`
    /// (`src/lj_obj.h:174`) and a userdata's payload is forced to eight bytes
    /// by the `align1` field at `src/lj_obj.h:330`, so blocks narrower than
    /// that give a state that misbehaves rather than one that reports trouble:
    /// the pointer arrived through `lua_Alloc` with no alignment attached to
    /// it, so there is nothing for the C API to check or complain about.
    /// Alignment of `max_align_t` is more than this needs and is always
    /// enough; four-byte alignment is not.
    pub fn initWithAllocator(
        allocator_function: c.lua_Alloc,
        user_data: ?*anyopaque,
    ) InitError!State {
        const state = c.lua_newstate(allocator_function, user_data) orelse
            return error.OutOfMemory;
        return .{ .raw = state };
    }

    /// Why a state could not be opened.
    ///
    /// One case, because there is one: `lua_newstate` answers null only when it
    /// could not seed its allocator or could not allocate from it
    /// (`src/lj_state.c:257-274`). A script that runs out of memory
    /// later does not come through here.
    pub const InitError = error{OutOfMemory};

    /// Close the state and release everything in it.
    ///
    /// `lua_close` (`src/lua.h:112`) frees the stack, the interned strings, the
    /// registry, every userdata and every trace the compiler had built. It is
    /// the only way to release a `State`, and it cannot fail: every block is
    /// released by a `nsize == 0` call to the allocator installed at that
    /// moment (`src/lj_state.c:243`), not to the one the state was opened with.
    ///
    /// Calling this twice is a no-op the second time. Calling it while a
    /// `Thread` or `Buffer` from this state is still in use is a use after free
    /// in C terms, and nothing here can detect it.
    pub fn deinit(self: *State) void {
        if (self.raw == null) return;
        c.lua_close(self.raw);
        self.raw = null;
    }

    /// The allocator and user pointer currently installed.
    ///
    /// Read back out of the library with `lua_getallocf` (`src/lua.h:245`), not
    /// remembered by this module: the library is the only place that knows.
    pub fn allocator(self: *const State) AllocatorPair {
        var user_data: ?*anyopaque = null;
        const function = c.lua_getallocf(self.raw, &user_data);
        return .{ .function = function, .user_data = user_data };
    }

    /// Install a different allocator, and get the previous pair back.
    ///
    /// `lua_setallocf` (`src/lua.h:246`) assigns its two fields and returns
    /// without touching a single block (`src/lj_api.c:1297-1302`). Everything
    /// the state has allocated so far is therefore still outstanding under the
    /// old allocator while the next allocation already goes to the new one.
    /// Returning the old pair is what makes this safe to use: put it back before
    /// `deinit`, which releases what is left through the allocator installed at
    /// that moment (`src/lj_state.c:243`). A caller who does not keep the answer
    /// owns that.
    ///
    /// Swapping the library's own allocator away and back also loses its pool:
    /// `lua_close` destroys that pool only while the installed callback is still
    /// the one the library installed (`src/lj_state.c:238-243`), so the pair
    /// `allocator` reported at the start is the pair to restore.
    ///
    /// A null `allocator_function` has no meaning here: the collector calls the
    /// installed callback for every block (`src/lj_gc.c:873`).
    pub fn setAllocator(
        self: *State,
        allocator_function: c.lua_Alloc,
        user_data: ?*anyopaque,
    ) AllocatorPair {
        const previous = self.allocator();
        c.lua_setallocf(self.raw, allocator_function, user_data);
        return previous;
    }

    // -- Stack ------------------------------------------------------------

    /// How many values are on the stack.
    pub fn top(self: *const State) usize {
        return @intCast(c.lua_gettop(self.raw));
    }

    /// Set the stack height.
    ///
    /// Growing past the current top fills with nil, which is how a C function
    /// reserves room; shrinking discards, which runs finalizers on collected
    /// values.
    pub fn setTop(self: *State, index: usize) void {
        c.lua_settop(self.raw, @intCast(index));
    }

    /// Resolve a possibly negative index against the current top.
    ///
    /// `index` of `-1` is the top value, as in C (`src/lua.h:39` defines the
    /// pseudo-indices and `lua_gettop` fixes the convention). An out-of-range
    /// index is returned unchanged, because Lua's own rules for those are a
    /// runtime error and this does not invent one here.
    pub fn absoluteIndex(self: *const State, index: Index) Index {
        if (index >= 0) return index;
        return @as(Index, @intCast(self.top())) + index + 1;
    }

    /// Push `count` nils, leaving room to fill them in.
    pub fn pushNil(self: *State, count: usize) void {
        for (0..count) |_| c.lua_pushnil(self.raw);
    }

    /// Discard the top `count` values.
    pub fn pop(self: *State, count: usize) void {
        self.setTop(self.top() - count);
    }

    /// Push a copy of the value at `index`.
    pub fn pushValue(self: *State, index: Index) void {
        c.lua_pushvalue(self.raw, index);
    }

    pub fn pushBoolean(self: *State, value: bool) void {
        c.lua_pushboolean(self.raw, if (value) 1 else 0);
    }

    pub fn pushInteger(self: *State, value: Integer) void {
        c.lua_pushinteger(self.raw, value);
    }

    pub fn pushNumber(self: *State, value: Number) void {
        c.lua_pushnumber(self.raw, value);
    }

    /// Push `text` with its length, so an embedded NUL survives.
    ///
    /// `lua_pushstring` would stop at the first NUL; this is
    /// `lua_pushlstring` (`src/lua.h:164`). Lua copies the bytes, so the
    /// caller's slice is not retained.
    pub fn pushString(self: *State, text: []const u8) void {
        c.lua_pushlstring(self.raw, text.ptr, text.len);
    }

    /// Push an arbitrary pointer as light userdata: a value with no destructor
    /// and no type, compared by address.
    pub fn pushLightUserData(self: *State, pointer: ?*anyopaque) void {
        c.lua_pushlightuserdata(self.raw, pointer);
    }

    /// Push a C function and `upvalues` values to close over.
    ///
    /// The values must already be on the stack, above the function, in order.
    pub fn pushCClosure(self: *State, function: c.lua_CFunction, upvalues: usize) void {
        c.lua_pushcclosure(self.raw, function, @intCast(upvalues));
    }

    /// Push a C function with no upvalues.
    pub fn pushCFunction(self: *State, function: c.lua_CFunction) void {
        c.lua_pushcclosure(self.raw, function, 0);
    }

    // -- Reading the stack ------------------------------------------------

    /// The type of the value at `index`, as `LUA_T*` (`src/lua.h:73-83`).
    pub fn typeOf(self: *const State, index: Index) Index {
        return c.lua_type(self.raw, index);
    }

    /// The type of the value at `index`, as a name.
    ///
    /// The library's own name for it (`src/lua.h:141`), so the strings are
    /// `"nil"`, `"boolean"`, `"number"`, `"string"`, `"table"`, `"function"`,
    /// `"userdata"`, `"thread"` and `"no value"`.
    pub fn typeName(self: *const State, index: Index) []const u8 {
        return std.mem.span(c.lua_typename(self.raw, self.typeOf(index)));
    }

    pub fn isNone(self: *const State, index: Index) bool {
        return self.typeOf(index) == c.LUA_TNONE;
    }

    pub fn isBoolean(self: *const State, index: Index) bool {
        return self.typeOf(index) == c.LUA_TBOOLEAN;
    }

    /// True for a number or a string that reads as one: `lua_isnumber` accepts
    /// both (`src/lua.h:136`), because Lua converts.
    pub fn isNumber(self: *const State, index: Index) bool {
        return c.lua_isnumber(self.raw, index) != 0;
    }

    pub fn isString(self: *const State, index: Index) bool {
        return c.lua_isstring(self.raw, index) != 0;
    }

    pub fn isTable(self: *const State, index: Index) bool {
        return self.typeOf(index) == c.LUA_TTABLE;
    }

    pub fn isFunction(self: *const State, index: Index) bool {
        return self.typeOf(index) == c.LUA_TFUNCTION;
    }

    pub fn isThread(self: *const State, index: Index) bool {
        return self.typeOf(index) == c.LUA_TTHREAD;
    }

    pub fn isUserdata(self: *const State, index: Index) bool {
        return c.lua_isuserdata(self.raw, index) != 0;
    }

    /// The truth of the value at `index`: everything but nil and false.
    pub fn toBoolean(self: *const State, index: Index) bool {
        return c.lua_toboolean(self.raw, index) != 0;
    }

    /// The value at `index` as a number, or 0 when it is not convertible.
    ///
    /// The silent 0 is Lua's own (`src/lua.h:147`). Use `toNumberX` when the
    /// difference matters.
    pub fn toNumber(self: *const State, index: Index) Number {
        return c.lua_tonumber(self.raw, index);
    }

    /// The value at `index` as a number, or null when it is not convertible.
    ///
    /// `lua_tonumberx` (`src/lua.h:353`) has no side effect and answers the
    /// question exactly, so this is the one to reach for when a wrong answer is
    /// worse than no answer.
    ///
    /// `lua_tonumberx` is one of the `From Lua 5.2` declarations
    /// (`src/lua.h:346-354`) that LuaJIT also provides, which is why the 5.1
    /// `toNumber` above answers a silent 0 instead.
    pub fn toNumberX(self: *const State, index: Index) ?Number {
        var converted: c_int = 0;
        const value = c.lua_tonumberx(self.raw, index, &converted);
        return if (converted != 0) value else null;
    }

    /// The value at `index` as an integer, truncating towards zero.
    ///
    /// `lua_tointeger` (`src/lua.h:148`) is an unchecked cast once the value
    /// reads as a number: `src/lj_obj.h:1010` defines the conversion as a plain
    /// C cast, so `3.5` becomes 3 and a number too large for `Integer` is
    /// undefined behaviour in C terms. This is Lua's shape, not a shortcut
    /// here; use `toIntegerX` when the answer has to be exact.
    pub fn toInteger(self: *const State, index: Index) Integer {
        return c.lua_tointeger(self.raw, index);
    }

    /// The value at `index` as an integer, or null when it does not read as a
    /// number at all.
    ///
    /// What `lua_tointegerx` (`src/lua.h:354`) actually decides is narrower than
    /// the name suggests: it sets its flag for any number *or* any string that
    /// parses as one (`src/lj_api.c:421-441`), and then casts exactly as
    /// `toInteger` does. So `null` means "this is not a number", not "this is
    /// not an integer": `"3.5"` answers 3, and only a string that does not parse,
    /// or a table or a function, answers null.
    ///
    /// `lua_tointegerx` is likewise one of the `From Lua 5.2` declarations
    /// (`src/lua.h:346-354`) that LuaJIT also provides.
    pub fn toIntegerX(self: *const State, index: Index) ?Integer {
        var converted: c_int = 0;
        const value = c.lua_tointegerx(self.raw, index, &converted);
        return if (converted != 0) value else null;
    }

    /// The value at `index` as a string.
    ///
    /// This converts in place: after the call the slot at `index` holds the
    /// string, not the number it held before. See "Strings" above.
    pub fn toString(self: *const State, index: Index) Borrowed {
        var length: usize = 0;
        const text = c.lua_tolstring(self.raw, index, &length) orelse
            return .{ .ptr = &[_]u8{}, .len = 0 };
        return .{ .ptr = text, .len = length };
    }

    /// The raw bytes of the value at `index`, without the conversion a number
    /// would get.
    ///
    /// Only for a value that already is a string: `objlen` on a number answers
    /// the length of the conversion `toString` would have made, so this is not
    /// a way to avoid the side effect.
    pub fn lengthOf(self: *const State, index: Index) usize {
        return @intCast(c.lua_objlen(self.raw, index));
    }

    /// The address of the value at `index`.
    ///
    /// Two values are raw-equal exactly when their addresses are equal, which
    /// is what `rawEqual` compares.
    pub fn toPointer(self: *const State, index: Index) ?*const anyopaque {
        return c.lua_topointer(self.raw, index);
    }

    /// `lua_equal`: the library's `==`, which runs metamethods.
    pub fn equal(self: *const State, first: Index, second: Index) bool {
        return c.lua_equal(self.raw, first, second) != 0;
    }

    /// `lua_rawequal`: identity without metamethods.
    pub fn rawEqual(self: *const State, first: Index, second: Index) bool {
        return c.lua_rawequal(self.raw, first, second) != 0;
    }

    /// The next key/value pair of the table at `index`, or false at its end.
    ///
    /// Leaves the two values on the stack when it answers true, which is Lua's
    /// convention: `nextIsValid` is a step in a loop, not a lookup.
    pub fn nextIsValid(self: *const State, index: Index) bool {
        return c.lua_next(self.raw, index) != 0;
    }

    // -- Tables and fields ------------------------------------------------

    pub fn newTable(self: *State) void {
        c.lua_createtable(self.raw, 0, 0);
    }

    pub fn createTable(self: *State, array_part: usize, hash_part: usize) void {
        c.lua_createtable(self.raw, @intCast(array_part), @intCast(hash_part));
    }

    /// Push `table[key]`, whatever its type.
    ///
    /// The key must be NUL-terminated, because it becomes a C string: a Lua
    /// string with an embedded NUL cannot be a key here. `rawGetI` is the entry
    /// point for positional keys.
    pub fn getField(self: *State, table: Index, key: [:0]const u8) void {
        c.lua_getfield(self.raw, table, key.ptr);
    }

    /// Set `table[key] = top`, popping the value.
    pub fn setField(self: *State, table: Index, key: [:0]const u8) void {
        c.lua_setfield(self.raw, table, key.ptr);
    }

    /// Push `table[n]`, by position in the array part.
    pub fn rawGetI(self: *State, table: Index, n: Index) void {
        c.lua_rawgeti(self.raw, table, n);
    }

    /// Set `table[n] = top`, by position in the array part.
    pub fn rawSetI(self: *State, table: Index, n: Index) void {
        c.lua_rawseti(self.raw, table, n);
    }

    /// Push a global. The name must be NUL-terminated, for `getField`'s reason.
    pub fn getGlobal(self: *State, name: [:0]const u8) void {
        c.lua_getfield(self.raw, c.LUA_GLOBALSINDEX, name.ptr);
    }

    /// Set a global to the top value, popping it.
    pub fn setGlobal(self: *State, name: [:0]const u8) void {
        c.lua_setfield(self.raw, c.LUA_GLOBALSINDEX, name.ptr);
    }

    /// Pop the top `count` values and push their concatenation
    /// (`src/lua.h:243`). N metamethods run; numbers concatenate as text.
    pub fn concat(self: *State, count: usize) void {
        c.lua_concat(self.raw, @intCast(count));
    }

    // -- Registry ---------------------------------------------------------

    /// Push the registry table (`src/lua.h:291`).
    ///
    /// The registry is where a C library keeps what it wants to keep: it is
    /// anchored for the life of the state, so anything a caller parks there is
    /// collected only with the state.
    pub fn pushRegistry(self: *State) void {
        c.lua_pushvalue(self.raw, c.LUA_REGISTRYINDEX);
    }

    /// Pop the top value and answer the reference that keeps it alive.
    ///
    /// `luaL_ref` (`src/lauxlib.h:62`) stores the value at the top of the
    /// stack under an integer key in the table at `table` -- normally the
    /// registry -- and pops it, and `unref` is how that reference goes back.
    /// It answers `LUA_REFNIL` or `LUA_NOREF` (`src/lauxlib.h:59-60`) for a
    /// value that must not be referenced; both are negative and neither is a
    /// reference, which is what lets a caller tell one from the other.
    pub fn ref(self: *State, table: Index) Index {
        return c.luaL_ref(self.raw, table);
    }

    /// Release a reference from `ref`.
    pub fn unref(self: *State, table: Index, reference: Index) void {
        c.luaL_unref(self.raw, table, reference);
    }

    // -- Standard libraries ------------------------------------------------

    /// Open every standard library, in upstream's order.
    ///
    /// This is `luaL_openlibs` (`src/lualib.h:38`): `_G` and `coroutine`, which
    /// `luaopen_base` installs in one call (`src/lib_base.c:705-707`), then
    /// `package`, `table`, `io`, `os`, `string`, `math`, `debug`, `bit` and
    /// `jit`, in upstream's order (`src/lib_init.c:18-30`) because these
    /// libraries register into each other.
    ///
    /// `ffi` and `string.buffer` are there for `require` as well, and neither
    /// one is a global: `luaL_openlibs` preloads `ffi`
    /// (`src/lib_init.c:32-37`), and `luaopen_string` preloads
    /// `string.buffer` into the same table as the `string` library opens
    /// (`src/lib_string.c:685-687`). Either is offered only where this build
    /// compiled it (`src/lj_arch.h:617-622`, `:624-629`), and reaching either
    /// is this facade's job: `State.openFfi` publishes `_G.ffi` and
    /// `State.openStringBuffer` publishes `string.buffer`.
    ///
    /// `io` opens the process's standard streams, and `os` reaches the process
    /// environment. A caller embedding a script it did not write has just handed
    /// that script both, and this function is the honest way to say so.
    pub fn openLibs(self: *State) void {
        c.luaL_openlibs(self.raw);
    }

    /// Open the FFI and install it as the global `ffi`.
    ///
    /// `luaL_openlibs` does not do this: it puts `ffi` in `_PRELOAD` and leaves
    /// a script to `require` it (`src/lib_init.c:32-36`). Upstream's
    /// `luaopen_ffi` creates no global either (`src/lib_ffi.c:855`); it returns
    /// the table and leaves the FFI state itself installed in the state.
    /// This calls it once and names the table.
    ///
    /// Calling it twice re-initialises the FFI's type state for this `lua_State`
    /// (`src/lj_ctype_init`), which invalidates cdata the state already holds.
    /// Call it once, right after opening the state. A provider built with
    /// `LUAJIT_DISABLE_FFI` or on an architecture with `LJ_ARCH_NOFFI`
    /// (`src/lj_arch.h:617-622`) has no FFI, and the script-visible effect is
    /// that `require "ffi"` fails there.
    pub fn openFfi(self: *State) void {
        const stack_top = self.top();
        _ = c.luaopen_ffi(self.raw);
        self.setGlobal(c.LUA_FFILIBNAME);
        self.setTop(stack_top);
    }

    /// Open `string.buffer` and install it as `string.buffer`.
    ///
    /// `luaopen_string_buffer` (`src/lib_buffer.c:351`) registers the methods
    /// into the string metatable and returns the table. It installs no global
    /// for itself, and this sets one, which is a decision this facade makes and
    /// not upstream's.
    ///
    /// The name is dotted, and the C API's field functions do not split on
    /// dots, so the `string` table is fetched and the field set on it. The
    /// stack order matters: `lua_setfield` takes the value from the top and
    /// the table from its argument, so the value is copied back up first.
    /// The `string` library has to be open already: the global by that name is
    /// what the field is set on, and `lua_setfield` on anything but a table
    /// raises through the longjmp path described in the module documentation.
    pub fn openStringBuffer(self: *State) void {
        const stack_top = self.top();
        _ = c.luaopen_string_buffer(self.raw); // buffer table on top
        self.getGlobal(c.LUA_STRLIBNAME); // string table above it
        self.pushValue(-2); // and the buffer table above that
        self.setField(-2, "buffer");
        self.setTop(stack_top);
    }

    // -- Loading and calling ----------------------------------------------

    /// Load `source` as a chunk named `chunk_name`, leaving it on the stack.
    ///
    /// Nothing has run yet. On failure the message is on the stack and the
    /// error says why; `errorMessage` reads it. `chunk_name` is what a later
    /// error message will name, and is not a path this module opens: pass null
    /// for the default.
    pub fn load(self: *State, source: []const u8, chunk_name: ?[*:0]const u8) RunError!void {
        const status = c.luaL_loadbuffer(self.raw, source.ptr, source.len, chunk_name);
        if (status == 0) return;
        return runError(status);
    }

    /// Load the file at `path`, leaving the chunk on the stack.
    ///
    /// The only entry point here that touches the filesystem, and the only one
    /// that can report `FileError`. `mode` is passed to
    /// `luaL_loadfilex` (`src/lauxlib.h:82-83`) and is `"b"` or `"t"`.
    pub fn loadFile(self: *State, path: [:0]const u8, mode: ?[*:0]const u8) RunError!void {
        const status = c.luaL_loadfilex(self.raw, path.ptr, mode);
        if (status == 0) return;
        return runError(status);
    }

    /// Call the function below `argument_count` arguments on the stack, letting
    /// an error escape.
    ///
    /// This is the unprotected `lua_call` (`src/lua.h:202`), which takes no
    /// index: the function is the value the arguments sit on top of.
    /// `api_call_base` answers `L->top - nargs` (`src/lj_api.c:1100-1110`), and
    /// the `lj_checkapi_slot(nargs+1)` in front of it (`src/lj_api.c:1116`) is
    /// what asserts that function is there. So push the function, then its
    /// arguments, in that order; there is nowhere to put an index.
    ///
    /// An error inside unwinds the Lua stack with a `longjmp` and skips any Zig
    /// frame in between, so this is only correct when the caller has no state to
    /// lose. `protectedCall` is what a caller normally wants; this exists for the
    /// cases that need to call a function that cannot fail.
    ///
    /// `result_count` is a count, or `multret` to keep every result. Nothing is
    /// returned either way: the results are on the stack.
    pub fn call(self: *State, argument_count: usize, result_count: Index) void {
        c.lua_call(self.raw, @intCast(argument_count), result_count);
    }

    /// Call the function below `argument_count` arguments on the stack, under a
    /// protected call.
    ///
    /// The stack arrangement is `call`'s and for the same reason: `lua_pcall`
    /// (`src/lua.h:203`) takes no index either, and `api_call_base` puts the
    /// function where the arguments start below it (`src/lj_api.c:1120-1135`).
    ///
    /// On failure the message is on the stack and the error says why. This is
    /// the call that makes `RunError` possible: an error inside becomes a
    /// returned value instead of an unwind.
    pub fn protectedCall(
        self: *State,
        argument_count: usize,
        result_count: Index,
    ) RunError!void {
        const status = c.lua_pcall(self.raw, @intCast(argument_count), result_count, 0);
        if (status == 0) return;
        return runError(status);
    }

    /// Load and run `source` under a protected call.
    ///
    /// This is `load` followed by `protectedCall(0, multret)`, which is what
    /// `luaL_dostring` does (`src/lauxlib.h:115-116`) with the stack handling
    /// spelled out. The results land in the slot the loaded chunk occupied,
    /// which is what `api_call_base` answers (`src/lj_api.c:1100-1110`), so
    /// `run("return 42", null)` leaves one number at index 1 on an empty stack
    /// and leaves it at the top on a non-empty one, with everything that was
    /// already there still below it. A failure lands the same way: the
    /// protected frame unwinds to the caller's own base
    /// (`src/lj_err.c:152-164`) and pushes the message where the function was.
    /// Call `setTop(0)` first when a caller wants absolute indices to mean
    /// that.
    ///
    /// The chunk is called with no arguments: the `0` in `protectedCall(0,
    /// multret)` is the argument count, so every parameter a chunk declares,
    /// and every value in its `...`, reads as `nil`. Nothing here changes
    /// that. To pass values, `load` the chunk, push them, and call
    /// `protectedCall(n, multret)` with `n` the number pushed - the chunk
    /// function is where `load` left it and the arguments sit above it, which
    /// is the arrangement `lua_pcall` counts from, and the results land in the
    /// slot the function occupied.
    pub fn run(self: *State, source: []const u8, chunk_name: ?[*:0]const u8) RunError!void {
        try self.load(source, chunk_name);
        try self.protectedCall(0, multret);
    }

    /// The message of the failure that just happened.
    ///
    /// Read from the top of the stack with `lua_tolstring`, so it converts that
    /// value in place and the result is a `Borrowed` with the lifetime described
    /// in "Strings". A stack with no error on it answers with whatever is on
    /// top, which is a caller mistake rather than a case to report.
    pub fn errorMessage(self: *const State) Borrowed {
        return self.toString(-1);
    }

    /// Raise `message` as a Lua error, unwinding to the protected call above.
    ///
    /// The message is pushed and `lua_error` is called, which is a `longjmp`:
    /// this does not return, and any Zig frame between here and the protected
    /// call is skipped rather than unwound. There must be one. `Args.typeError`
    /// and `Args.argError` are the same shape for a C function's own argument
    /// checks.
    pub fn raise(self: *State, message: []const u8) noreturn {
        self.pushString(message);
        _ = c.lua_error(self.raw);
        unreachable;
    }

    // -- Garbage collection -----------------------------------------------

    /// Run one full collection cycle.
    ///
    /// Synchronous and complete: after it returns, everything unreachable has
    /// been collected and the weak tables have been cleared.
    pub fn collect(self: *State) void {
        _ = c.lua_gc(self.raw, c.LUA_GCCOLLECT, 0);
    }

    /// Run one incremental step, and report whether it finished a cycle.
    ///
    /// `lua_gc(L, LUA_GCSTEP, 0)` (`src/lua.h:232`) drops the threshold to
    /// where the state is now and steps until either the step budget runs out or
    /// the collector returns to its pause state (`src/lj_api.c:1263-1272`), and
    /// answers 1 only for the second (`src/lj_gc.c:741-745`). So true means "a
    /// full cycle just completed", not "there is more to do". `isCollecting` is
    /// the separate question about what the collector is doing right now.
    pub fn stepCollection(self: *State) bool {
        return c.lua_gc(self.raw, c.LUA_GCSTEP, 0) != 0;
    }

    /// Whether a collection is in progress right now.
    pub fn isCollecting(self: *const State) bool {
        return c.lua_gc(self.raw, c.LUA_GCISRUNNING, 0) != 0;
    }

    /// Bytes the state is using, in kilobytes, as the library counts them.
    ///
    /// `LUA_GCCOUNT` (`src/lua.h:225`) is the whole number of kilobytes.
    pub fn countKilobytes(self: *const State) usize {
        return @intCast(c.lua_gc(self.raw, c.LUA_GCCOUNT, 0));
    }

    /// Bytes of that last collection cycle, on top of `countKilobytes`.
    ///
    /// `LUA_GCCOUNTB` (`src/lua.h:226`) is the remainder the library could not
    /// express in kilobytes. The two together are the byte count Lua 5.1
    /// reports; `bytesInUse` is the sum.
    pub fn countBytesRemainder(self: *const State) usize {
        return @intCast(c.lua_gc(self.raw, c.LUA_GCCOUNTB, 0));
    }

    /// The library's memory total, in bytes.
    pub fn bytesInUse(self: *const State) usize {
        return self.countKilobytes() * 1024 + self.countBytesRemainder();
    }

    /// Set the collector's pause ratio, as a percentage (`LUA_GCSETPAUSE`).
    pub fn setPause(self: *State, percent: usize) void {
        _ = c.lua_gc(self.raw, c.LUA_GCSETPAUSE, @intCast(percent));
    }

    /// Set the collector's step multiplier (`LUA_GCSETSTEPMUL`).
    pub fn setStepMultiplier(self: *State, percent: usize) void {
        _ = c.lua_gc(self.raw, c.LUA_GCSETSTEPMUL, @intCast(percent));
    }

    // -- Coroutines -------------------------------------------------------

    /// Create a coroutine in this state and leave it on the stack.
    ///
    /// `lua_newthread` (`src/lua.h:113`) creates a `lua_State` that shares this
    /// one's globals and collector and has no allocator of its own. It is
    /// pushed here, which is also what keeps it alive: a coroutine nothing
    /// references is collected like anything else, and closing this state
    /// closes it.
    ///
    /// The returned `Thread` holds that pointer itself rather than the slot,
    /// so nothing here has to look the coroutine up again to run it. What
    /// keeps it alive is the copy this call pushed: a caller who drops that
    /// slot and then collects leaves `Thread.raw` pointing at freed memory.
    pub fn newThread(self: *State) Thread {
        const state = c.lua_newthread(self.raw);
        return .{ .raw = state };
    }

    /// Whether a thread may yield where it is: `lua_isyieldable`
    /// (`src/lua.h:357`), a Lua 5.3 declaration LuaJIT also provides.
    pub fn isYieldable(self: *const State) bool {
        return c.lua_isyieldable(self.raw) != 0;
    }
};

/// A coroutine: a `lua_State` this state owns.
///
/// It shares its parent's globals, registry and collector, and it has no
/// allocator of its own: every block it uses was allocated by the state that
/// created it, under that state's allocator. It has no separate lifetime
/// either. A `Thread` borrows: it is valid only while the state that created it
/// is, `deinit` on that state releases what the coroutine was using, and a
/// `Thread` kept past that is a dangling pointer rather than a handle.
///
/// The handle is the library's own pointer, taken when the coroutine was
/// created. `lua_tothread` is not consulted again: a stack slot that has been
/// overwritten no longer describes this coroutine, and quietly creating a
/// replacement would answer with a different one.
pub const Thread = struct {
    /// The coroutine's own state, as `lua_newthread` answered.
    raw: ?*c.lua_State,

    /// Resume the coroutine with `argument_count` values on its stack.
    ///
    /// The function to run is whatever sits on the thread's own stack below
    /// those values (`api_call_base`, `src/lj_api.c:1100-1110`), and a fresh
    /// coroutine's stack is empty, so push it there before resuming.
    ///
    /// Returns when the coroutine finishes, errors, or yields; a yield is not a
    /// failure and reports nothing. On an error the message is on the
    /// coroutine's own stack, where `errorMessage` reads it.
    pub fn @"resume"(self: Thread, argument_count: usize) RunError!void {
        const resume_status = c.lua_resume(self.raw, @intCast(argument_count));
        if (resume_status == 0 or resume_status == c.LUA_YIELD) return;
        return runError(resume_status);
    }

    /// `lua_status` (`src/lua.h:216`): `LUA_OK`, or the status of the error that
    /// stopped it.
    pub fn status(self: Thread) Index {
        return c.lua_status(self.raw);
    }

    /// The message from a failed resume, read off the coroutine's own stack.
    pub fn errorMessage(self: Thread) Borrowed {
        var length: usize = 0;
        const text = c.lua_tolstring(self.raw, -1, &length) orelse
            return .{ .ptr = &[_]u8{}, .len = 0 };
        return .{ .ptr = text, .len = length };
    }
};

/// The FFI-adjacent argument reader for a function Lua is calling.
///
/// Lua calls a C function with that call's arguments and nothing else on the
/// function's own stack, and argument 1 is at index 1: the library resolves
/// `narg` against `L->base` (`src/lj_err.c:1106`), `L->base` is where that
/// frame's arguments start, and `lua_gettop` counts them from there
/// (`src/lj_api.c:145-148`). `Args` is a view of that stack from a base index,
/// so a C function written in Zig reads its arguments by number the way a C one
/// does:
///
/// ```zig
/// fn doubleArgument(l: ?*luajit.c.lua_State) callconv(.c) luajit.Index {
///     var state = luajit.State{ .raw = l };
///     const args = luajit.Args{ .state = &state, .base = 1 };
///     const value = args.checkInteger(1);
///     state.pushInteger(value * 2);
///     return 1;
/// }
/// ```
///
/// The `State` borrows the `lua_State` Lua handed the function, so it has to be
/// declared `var` and must not outlive the call. It is not an owner; see the
/// note on `State` about a state this module did not open.
///
/// Every `check*` that can fail raises through `lj_err_argt` or `lj_err_arg`
/// (`src/lj_api.c:245-255`, `:447-464`, `:512-529`), and that raise is the
/// `longjmp` described above. That is correct here and only here: there is a
/// Lua error handler above this frame, because Lua called it. The same call
/// from a plain Zig function would skip that frame.
pub const Args = struct {
    state: *State,
    /// The stack index of argument 1, which is `1` for the function Lua is
    /// calling: that frame holds that call's arguments and nothing else.
    base: Index,

    /// Make sure there is room for `size` more values, or raise.
    pub fn checkStack(self: Args, size: usize) void {
        c.luaL_checkstack(self.state.raw, @intCast(size), "too many arguments to a Lua C function");
    }

    /// Argument `n` as an integer, or raise if it is not one.
    pub fn checkInteger(self: Args, n: usize) Integer {
        return c.luaL_checkinteger(self.state.raw, self.index(n));
    }

    /// Argument `n` as an integer, or `default` if it is absent or nil.
    pub fn optInteger(self: Args, n: usize, default: Integer) Integer {
        return c.luaL_optinteger(self.state.raw, self.index(n), default);
    }

    /// Argument `n` as a number, or raise if it is not one.
    pub fn checkNumber(self: Args, n: usize) Number {
        return c.luaL_checknumber(self.state.raw, self.index(n));
    }

    /// Argument `n` as a number, or `default` if it is absent or nil.
    pub fn optNumber(self: Args, n: usize, default: Number) Number {
        return c.luaL_optnumber(self.state.raw, self.index(n), default);
    }

    /// Argument `n` as a string, or raise if it is not one.
    ///
    /// The result borrows the argument's bytes from the callee's stack.
    ///
    /// A number argument is converted in place, exactly as `State.toString`
    /// converts the slot it reads (`src/lj_api.c:517-522`), so the argument is
    /// a string afterwards.
    pub fn checkString(self: Args, n: usize) Borrowed {
        var length: usize = 0;
        const text = c.luaL_checklstring(self.state.raw, self.index(n), &length);
        return .{ .ptr = text, .len = length };
    }

    /// Argument `n` as a string, or `default` if it is absent or nil.
    ///
    /// `default` is a NUL-terminated string or null, because it goes straight
    /// into `luaL_optlstring` as the C string to answer with. A null default
    /// makes the library answer null, which comes back here as an empty
    /// `Borrowed` rather than as a null pointer this module would have to
    /// carry.
    pub fn optString(self: Args, n: usize, default: ?[:0]const u8) Borrowed {
        var length: usize = 0;
        const fallback: ?[*:0]const u8 = if (default) |text| text.ptr else null;
        const text = c.luaL_optlstring(self.state.raw, self.index(n), fallback, &length) orelse
            return .{ .ptr = &[_]u8{}, .len = 0 };
        return .{ .ptr = text, .len = length };
    }

    /// Raise unless argument `n` is of type `expected`.
    pub fn checkType(self: Args, n: usize, expected: Index) void {
        c.luaL_checktype(self.state.raw, self.index(n), expected);
    }

    /// Raise unless there is an argument `n` at all.
    pub fn checkAny(self: Args, n: usize) void {
        c.luaL_checkany(self.state.raw, self.index(n));
    }

    /// Raise `message` about argument `n`, naming the argument and the library
    /// that called it.
    ///
    /// `message` must be NUL-terminated because it becomes a C string. Does not
    /// return: `luaL_argerror` calls `lua_error`, which `longjmp`s to the
    /// protected call above the C function Lua is running.
    pub fn argError(self: Args, n: usize, message: [:0]const u8) noreturn {
        _ = c.luaL_argerror(self.state.raw, self.index(n), message.ptr);
        unreachable;
    }

    /// Raise a type error about argument `n`, naming the type that was wanted.
    ///
    /// `expected` is a type *name*, as `luaL_typerror` takes it
    /// (`src/lauxlib.h:32`), so it is NUL-terminated: `"number"`, `"table"`,
    /// `"string"`. It goes into the message, so it is text and nothing else.
    /// Does not return, for the same reason `argError` does not.
    pub fn typeError(self: Args, n: usize, expected: [:0]const u8) noreturn {
        _ = c.luaL_typerror(self.state.raw, self.index(n), expected.ptr);
        unreachable;
    }

    fn index(self: Args, n: usize) Index {
        return self.base + @as(Index, @intCast(n)) - 1;
    }
};

/// On-stack string building, without the concatenation a script would do.
///
/// `luaL_Buffer` (`src/lauxlib.h:135-140`) is a fixed `LUAL_BUFFERSIZE` array in
/// the C caller's frame, so it is initialized *in place*: `init` must be called
/// on the variable that stays, never on a copy, because `luaL_buffinit` stores a
/// pointer to the array inside the struct it was given.
pub const Buffer = struct {
    raw: c.luaL_Buffer = undefined,

    /// Prepare this buffer against `state`.
    pub fn init(self: *Buffer, state: *State) void {
        c.luaL_buffinit(state.raw, &self.raw);
    }

    /// Append `text` with its length, so an embedded NUL survives.
    pub fn add(self: *Buffer, text: []const u8) void {
        c.luaL_addlstring(&self.raw, text.ptr, text.len);
    }

    /// Push the whole buffer as one string.
    ///
    /// The buffer is spent afterwards: call `init` again before reusing it,
    /// which is what `luaL_buffinit` expects.
    pub fn push(self: *Buffer) void {
        c.luaL_pushresult(&self.raw);
    }
};

/// LuaJIT's compiler control.
///
/// These are `luaJIT_setmode` and the profiling calls from `src/luajit.h`, and
/// they exist because this is LuaJIT: PUC-Rio's Lua 5.1 has no compiler to
/// control. `luaJIT_setmode` takes a target index and a mode, where the mode is
/// a target (`LUAJIT_MODE_ENGINE`, `LUAJIT_MODE_FUNC`, ...) or'ed with an action
/// (`LUAJIT_MODE_ON`, `LUAJIT_MODE_OFF`, `LUAJIT_MODE_FLUSH`); the constants
/// below are those values, taken from the translation.
pub const jit = struct {
    /// The whole compiler engine.
    pub const engine = c.LUAJIT_MODE_ENGINE;
    /// One function, the one at the given index.
    pub const func = c.LUAJIT_MODE_FUNC;
    /// That function and its subroutines.
    pub const all_functions = c.LUAJIT_MODE_ALLFUNC;
    /// Its subroutines only.
    pub const all_subroutines = c.LUAJIT_MODE_ALLSUBFUNC;
    /// One compiled trace, by index.
    pub const trace = c.LUAJIT_MODE_TRACE;

    /// Turn the feature on.
    pub const on = c.LUAJIT_MODE_ON;
    /// Turn the feature off.
    pub const off = c.LUAJIT_MODE_OFF;
    /// Drop compiled code for the target without changing whether it compiles.
    pub const flush = c.LUAJIT_MODE_FLUSH;

    /// Apply `mode` to the target at `index`, and report whether it worked.
    ///
    /// The index is a function index for `func` and a trace number for `trace`;
    /// for `engine` it is ignored, which is why `setEngine*` passes 0. The
    /// answer is `luaJIT_setmode`'s own (`src/luajit.h:65`): false when the
    /// target does not exist or is not compiled code.
    pub fn setMode(state: *State, index: Index, mode: Index) bool {
        return c.luaJIT_setmode(state.raw, index, mode) != 0;
    }

    /// Turn the whole compiler engine on or off.
    pub fn setEngine(state: *State, mode: Index) bool {
        return setMode(state, 0, engine | mode);
    }

    /// Turn the engine off. Traces already compiled stay until flushed.
    pub fn disable(state: *State) bool {
        return setEngine(state, off);
    }

    /// Turn the engine on.
    pub fn enable(state: *State) bool {
        return setEngine(state, on);
    }

    /// Drop every compiled trace, leaving the engine's on/off state alone.
    pub fn flushEngine(state: *State) bool {
        return setEngine(state, flush);
    }

    /// Drop one compiled trace.
    pub fn flushTrace(state: *State, trace_index: Index) bool {
        return setMode(state, trace_index, trace | flush);
    }

    /// Start the sampling profiler, with `callback` called per interval.
    ///
    /// `mode` is the format string the profiler's own stack dumps use. The
    /// callback is called from whichever thread the running script is on, so it
    /// must not call back into the state it was given.
    pub fn profileStart(
        state: *State,
        mode: [:0]const u8,
        callback: c.luaJIT_profile_callback,
        data: ?*anyopaque,
    ) void {
        c.luaJIT_profile_start(state.raw, mode.ptr, callback, data);
    }

    /// Stop the profiler and release its buffer.
    pub fn profileStop(state: *State) void {
        c.luaJIT_profile_stop(state.raw);
    }

    /// The profiler's own stack dump, as one string.
    ///
    /// Borrowed from the state, like every other string here.
    pub fn profileDumpStack(state: *const State, format: [:0]const u8, depth: Index) Borrowed {
        var length: usize = 0;
        const text = c.luaJIT_profile_dumpstack(state.raw, format.ptr, depth, &length) orelse
            return .{ .ptr = &[_]u8{}, .len = 0 };
        return .{ .ptr = text, .len = length };
    }
};