// SPDX-License-Identifier: MIT

//! Zig facade over LuaJIT's Lua 5.1 C API.
//! `State` owns Lua state; `Borrowed` strings and `Thread` handles borrow it.

const std = @import("std");

/// Translated LuaJIT C declarations, available beside this facade.
/// Use `c` for ABI declarations that the facade does not wrap.
pub const c = @import("c");

const rt = @import("rt");

/// Whether native symbols are resolved at run time instead of linked.
/// This is a comptime constant.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Select an explicit file path or platform-loader name; no fallback is used.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Errors returned when loading a runtime provider.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the selected provider; same-request calls are idempotent, concurrent calls wait.
/// Failures can be retried; reentrant calls return an error. Linked builds panic.
pub fn load(source: LoadSource) LoadError!void {
    if (comptime runtime_loaded) return c.load(source);
    std.debug.panic(
        "luajit: load was called on a linked build; this module is not " ++
            "runtime-loaded, so there is no library to load. Build with " ++
            "runtime loading configured, or do not call load.",
        .{},
    );
}

/// The successful provider request, or null before loading and in linked builds.
pub fn loadedSource() ?LoadSource {
    if (comptime runtime_loaded) return c.loadedSource();
    return null;
}

/// LuaJIT's `lua_Number` type (`double`).
pub const Number = c.lua_Number;

/// LuaJIT's `lua_Integer` type (`ptrdiff_t`).
pub const Integer = c.lua_Integer;

/// A Lua stack index; negative indices count back from the top.
pub const Index = c_int;

/// `LUA_MULTRET`: keep every result from a chunk.
pub const multret: Index = c.LUA_MULTRET;

/// `LUA_MINSTACK`: stack space a C function may assume.
pub const min_c_stack: usize = c.LUA_MINSTACK;

/// The Lua version string from the translated header.
pub const lua_version: [:0]const u8 = c.LUA_VERSION;

/// The LuaJIT version string from the translated header.
pub const luajit_version: [:0]const u8 = c.LUAJIT_VERSION;

/// A view of a Lua-owned string; valid until its value is removed or collected.
pub const Borrowed = struct {
    ptr: [*]const u8,
    len: usize,

    /// The bytes without a NUL or copy.
    pub fn slice(self: Borrowed) []const u8 {
        return self.ptr[0..self.len];
    }

    /// Compare length and contents.
    pub fn eql(self: Borrowed, other: []const u8) bool {
        return std.mem.eql(u8, self.slice(), other);
    }

    /// Copy to a NUL-terminated caller buffer; returns `NoRoom` if it cannot fit.
    /// The result borrows the buffer.
    pub fn copy(self: Borrowed, buffer: []u8) error{NoRoom}![:0]const u8 {
        if (self.len >= buffer.len) return error.NoRoom;
        @memcpy(buffer[0..self.len], self.ptr[0..self.len]);
        buffer[self.len] = 0;
        return buffer[0..self.len :0];
    }

    /// Copy the bytes into caller-owned memory.
    pub fn dup(self: Borrowed, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return allocator.dupe(u8, self.slice());
    }
};

/// LuaJIT's allocator callback and its caller-owned context pointer.
pub const AllocatorPair = struct {
    /// The callback the library calls for every block it takes and gives back.
    function: c.lua_Alloc,
    /// The pointer handed back to `function` unchanged: the caller's own.
    user_data: ?*anyopaque,
};

/// LuaJIT load/call errors; unknown status codes map to `UnexpectedStatus`.
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

/// One of LuaJIT's standard libraries.
pub const Library = enum {
    /// Opens `_G` and `coroutine`.
    base,
    package,
    table,
    io,
    os,
    string,
    math,
    debug,
    /// LuaJIT's `bit` extension.
    bit,
    /// LuaJIT's `jit` control library.
    jit,
    /// The FFI module; `openLibs` preloads it but does not install a global.
    ffi,
    /// LuaJIT's `string.buffer` extension; use `State.openStringBuffer` to name it.
    string_buffer,

    /// Names of globals this opener installs, in upstream order.
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

    /// Open one library and restore the stack; use `openFfi` or `openStringBuffer` for those globals.
    /// `.package.open` requires a Lua call frame; use `State.openLibs` or call it from Lua.
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

/// An owned Lua state. A wrapper around a state passed to a Lua callback borrows it and must not call `deinit`.
pub const State = struct {
    /// Native `lua_State` pointer; null after `deinit`.
    raw: ?*c.lua_State,

    /// Open a state with LuaJIT's allocator; returns `OutOfMemory` if creation fails.
    pub fn init() InitError!State {
        const state = c.luaL_newstate() orelse return error.OutOfMemory;
        return .{ .raw = state };
    }

    /// Open a state with the caller's allocator and context; both remain caller-owned through `deinit`.
    /// The callback must be non-null and return blocks aligned to at least 8 bytes; creation may return `OutOfMemory`.
    pub fn initWithAllocator(
        allocator_function: c.lua_Alloc,
        user_data: ?*anyopaque,
    ) InitError!State {
        const state = c.lua_newstate(allocator_function, user_data) orelse
            return error.OutOfMemory;
        return .{ .raw = state };
    }

    /// State creation fails only when allocation fails.
    pub const InitError = error{OutOfMemory};

    /// Close the state, release its allocations, and clear `raw`.
    /// Do not use `Thread` or `Buffer` values after closing their state.
    pub fn deinit(self: *State) void {
        if (self.raw == null) return;
        c.lua_close(self.raw);
        self.raw = null;
    }

    /// The allocator callback and context currently installed in LuaJIT.
    pub fn allocator(self: *const State) AllocatorPair {
        var user_data: ?*anyopaque = null;
        const function = c.lua_getallocf(self.raw, &user_data);
        return .{ .function = function, .user_data = user_data };
    }

    /// Install a new allocator pair and return the previous pair; existing blocks are not migrated.
    /// Restore the previous pair before `deinit` to release remaining blocks correctly.
    pub fn setAllocator(
        self: *State,
        allocator_function: c.lua_Alloc,
        user_data: ?*anyopaque,
    ) AllocatorPair {
        const previous = self.allocator();
        c.lua_setallocf(self.raw, allocator_function, user_data);
        return previous;
    }

    /// How many values are on the stack.
    pub fn top(self: *const State) usize {
        return @intCast(c.lua_gettop(self.raw));
    }

    /// Set stack height; growth fills with nil and shrinkage discards values.
    /// Discarded values may run finalizers.
    pub fn setTop(self: *State, index: usize) void {
        c.lua_settop(self.raw, @intCast(index));
    }

    /// Resolve a negative index against the current stack top.
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

    /// Push `text` by length, preserving embedded NULs; Lua copies the bytes.
    pub fn pushString(self: *State, text: []const u8) void {
        c.lua_pushlstring(self.raw, text.ptr, text.len);
    }

    /// Push a pointer as light userdata, compared by address and without a destructor.
    pub fn pushLightUserData(self: *State, pointer: ?*anyopaque) void {
        c.lua_pushlightuserdata(self.raw, pointer);
    }

    /// Push a C function and the `upvalues` already above it on the stack.
    pub fn pushCClosure(self: *State, function: c.lua_CFunction, upvalues: usize) void {
        c.lua_pushcclosure(self.raw, function, @intCast(upvalues));
    }

    /// Push a C function with no upvalues.
    pub fn pushCFunction(self: *State, function: c.lua_CFunction) void {
        c.lua_pushcclosure(self.raw, function, 0);
    }

    /// The type of the value at `index`, as `LUA_T*` (`src/lua.h:73-83`).
    pub fn typeOf(self: *const State, index: Index) Index {
        return c.lua_type(self.raw, index);
    }

    /// Return Lua's type name for the value at `index`.
    pub fn typeName(self: *const State, index: Index) []const u8 {
        return std.mem.span(c.lua_typename(self.raw, self.typeOf(index)));
    }

    pub fn isNone(self: *const State, index: Index) bool {
        return self.typeOf(index) == c.LUA_TNONE;
    }

    pub fn isBoolean(self: *const State, index: Index) bool {
        return self.typeOf(index) == c.LUA_TBOOLEAN;
    }

    /// True for numbers and numeric strings, matching `lua_isnumber`.
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

    /// Convert to a number, or return 0; use `toNumberX` to distinguish failure.
    pub fn toNumber(self: *const State, index: Index) Number {
        return c.lua_tonumber(self.raw, index);
    }

    /// Convert without changing the stack; return null if the value is not numeric.
    pub fn toNumberX(self: *const State, index: Index) ?Number {
        var converted: c_int = 0;
        const value = c.lua_tonumberx(self.raw, index, &converted);
        return if (converted != 0) value else null;
    }

    /// Convert to `Integer`, truncating fractions; out-of-range values are undefined.
    pub fn toInteger(self: *const State, index: Index) Integer {
        return c.lua_tointeger(self.raw, index);
    }

    /// Convert to `Integer`; numeric strings are accepted and fractions truncate.
    /// Return null only when the value cannot be read as a number.
    pub fn toIntegerX(self: *const State, index: Index) ?Integer {
        var converted: c_int = 0;
        const value = c.lua_tointegerx(self.raw, index, &converted);
        return if (converted != 0) value else null;
    }

    /// Convert the slot to a string and return its borrowed bytes.
    /// Numeric values change to strings in place.
    pub fn toString(self: *const State, index: Index) Borrowed {
        var length: usize = 0;
        const text = c.lua_tolstring(self.raw, index, &length) orelse
            return .{ .ptr = &[_]u8{}, .len = 0 };
        return .{ .ptr = text, .len = length };
    }

    /// Return the value's length; numbers use their string-conversion length.
    pub fn lengthOf(self: *const State, index: Index) usize {
        return @intCast(c.lua_objlen(self.raw, index));
    }

    /// Return the value's address; raw-equal values have the same address.
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

    /// Advance Lua's `next` protocol, leaving key and value on the stack when true.
    /// Return false when the table has no next entry.
    pub fn nextIsValid(self: *const State, index: Index) bool {
        return c.lua_next(self.raw, index) != 0;
    }

    pub fn newTable(self: *State) void {
        c.lua_createtable(self.raw, 0, 0);
    }

    pub fn createTable(self: *State, array_part: usize, hash_part: usize) void {
        c.lua_createtable(self.raw, @intCast(array_part), @intCast(hash_part));
    }

    /// Push `table[key]`; `key` must be NUL-terminated.
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

    /// Concatenate the top `count` values; concatenation metamethods may run.
    pub fn concat(self: *State, count: usize) void {
        c.lua_concat(self.raw, @intCast(count));
    }

    /// Push the registry table, which keeps referenced values alive until state close.
    pub fn pushRegistry(self: *State) void {
        c.lua_pushvalue(self.raw, c.LUA_REGISTRYINDEX);
    }

    /// Pop the top value into a table reference; nil and no-reference cases return `LUA_REFNIL` or `LUA_NOREF`.
    pub fn ref(self: *State, table: Index) Index {
        return c.luaL_ref(self.raw, table);
    }

    /// Release a reference from `ref`.
    pub fn unref(self: *State, table: Index, reference: Index) void {
        c.luaL_unref(self.raw, table, reference);
    }

    /// Open LuaJIT's standard libraries, including process I/O and environment access.
    /// FFI and `string.buffer` are preloaded, not installed as globals.
    pub fn openLibs(self: *State) void {
        c.luaL_openlibs(self.raw);
    }

    /// Initialize FFI and install the global `ffi`; call once per state before use.
    /// `openLibs` only preloads FFI, and some builds disable it.
    pub fn openFfi(self: *State) void {
        const stack_top = self.top();
        _ = c.luaopen_ffi(self.raw);
        self.setGlobal(c.LUA_FFILIBNAME);
        self.setTop(stack_top);
    }

    /// Install LuaJIT's string-buffer module as `string.buffer`.
    /// The `string` library must be open; the stack is restored afterwards.
    pub fn openStringBuffer(self: *State) void {
        const stack_top = self.top();
        _ = c.luaopen_string_buffer(self.raw); // buffer table on top
        self.getGlobal(c.LUA_STRLIBNAME); // string table above it
        self.pushValue(-2); // and the buffer table above that
        self.setField(-2, "buffer");
        self.setTop(stack_top);
    }

    /// Compile `source` as `chunk_name`, leaving the function on the stack.
    /// Return `RunError` on failure and leave the error message on the stack.
    pub fn load(self: *State, source: []const u8, chunk_name: ?[*:0]const u8) RunError!void {
        const status = c.luaL_loadbuffer(self.raw, source.ptr, source.len, chunk_name);
        if (status == 0) return;
        return runError(status);
    }

    /// Load a file; `mode` selects text or binary.
    /// Return `RunError`, including `FileError`.
    pub fn loadFile(self: *State, path: [:0]const u8, mode: ?[*:0]const u8) RunError!void {
        const status = c.luaL_loadfilex(self.raw, path.ptr, mode);
        if (status == 0) return;
        return runError(status);
    }

    /// Call the function below its arguments; `result_count` selects results on the stack.
    /// Unprotected errors longjmp past Zig frames; use `protectedCall` when errors are possible.
    pub fn call(self: *State, argument_count: usize, result_count: Index) void {
        c.lua_call(self.raw, @intCast(argument_count), result_count);
    }

    /// Protected call of the function below its arguments; results or error text stay on the stack.
    /// Return Lua failures as `RunError`; use `multret` to keep all results.
    pub fn protectedCall(
        self: *State,
        argument_count: usize,
        result_count: Index,
    ) RunError!void {
        const status = c.lua_pcall(self.raw, @intCast(argument_count), result_count, 0);
        if (status == 0) return;
        return runError(status);
    }

    /// Compile and run `source` with no arguments under a protected call.
    /// Return `RunError`; results or the failure message remain on the stack.
    pub fn run(self: *State, source: []const u8, chunk_name: ?[*:0]const u8) RunError!void {
        try self.load(source, chunk_name);
        try self.protectedCall(0, multret);
    }

    /// Read the top stack value as borrowed error text.
    pub fn errorMessage(self: *const State) Borrowed {
        return self.toString(-1);
    }

    /// Raise `message` as a Lua error with `longjmp`.
    /// Call only inside a protected call; intervening Zig frames are skipped.
    pub fn raise(self: *State, message: []const u8) noreturn {
        self.pushString(message);
        _ = c.lua_error(self.raw);
        unreachable;
    }

    /// Run a full collection cycle; unreachable values are reclaimed before return.
    pub fn collect(self: *State) void {
        _ = c.lua_gc(self.raw, c.LUA_GCCOLLECT, 0);
    }

    /// Run an incremental collection step; true means a full cycle completed.
    pub fn stepCollection(self: *State) bool {
        return c.lua_gc(self.raw, c.LUA_GCSTEP, 0) != 0;
    }

    /// Whether a collection is in progress right now.
    pub fn isCollecting(self: *const State) bool {
        return c.lua_gc(self.raw, c.LUA_GCISRUNNING, 0) != 0;
    }

    /// The integer kilobytes of memory the state uses.
    pub fn countKilobytes(self: *const State) usize {
        return @intCast(c.lua_gc(self.raw, c.LUA_GCCOUNT, 0));
    }

    /// The remainder in bytes, added to `countKilobytes` for the full count.
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

    /// Create a coroutine and leave its owning reference on the stack.
    /// The returned `Thread` borrows the state and is invalid after state close.
    pub fn newThread(self: *State) Thread {
        const state = c.lua_newthread(self.raw);
        return .{ .raw = state };
    }

    /// Whether this coroutine may yield.
    pub fn isYieldable(self: *const State) bool {
        return c.lua_isyieldable(self.raw) != 0;
    }
};

/// A coroutine handle borrowed from its parent `State`; it is invalid after state close.
pub const Thread = struct {
    /// The coroutine's native state pointer, borrowed from its parent.
    raw: ?*c.lua_State,

    /// Resume with `argument_count` values already on the coroutine's stack.
    /// Return on completion or yield; errors return `RunError` and leave text on its stack.
    pub fn @"resume"(self: Thread, argument_count: usize) RunError!void {
        const resume_status = c.lua_resume(self.raw, @intCast(argument_count));
        if (resume_status == 0 or resume_status == c.LUA_YIELD) return;
        return runError(resume_status);
    }

    /// Lua status of this coroutine.
    pub fn status(self: Thread) Index {
        return c.lua_status(self.raw);
    }

    /// The borrowed message left on the coroutine stack by a failed resume.
    pub fn errorMessage(self: Thread) Borrowed {
        var length: usize = 0;
        const text = c.lua_tolstring(self.raw, -1, &length) orelse
            return .{ .ptr = &[_]u8{}, .len = 0 };
        return .{ .ptr = text, .len = length };
    }
};

/// Arguments to a Lua-called C function; this view borrows that call's stack.
/// Failed `check*` calls raise into Lua and must run under its protected call.
pub const Args = struct {
    state: *State,
    /// Stack index where argument 1 begins.
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

    /// Read argument `n` as borrowed bytes; numeric values convert in place.
    /// The bytes borrow the Lua callback's stack.
    pub fn checkString(self: Args, n: usize) Borrowed {
        var length: usize = 0;
        const text = c.luaL_checklstring(self.state.raw, self.index(n), &length);
        return .{ .ptr = text, .len = length };
    }

    /// Read optional argument `n` as borrowed bytes; numeric values may convert in place.
    /// `default` must be NUL-terminated; null yields an empty view.
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

    /// Raise a NUL-terminated message about argument `n`.
    /// Does not return; `luaL_argerror` longjmps to Lua's protected call.
    pub fn argError(self: Args, n: usize, message: [:0]const u8) noreturn {
        _ = c.luaL_argerror(self.state.raw, self.index(n), message.ptr);
        unreachable;
    }

    /// Raise a type error; `expected` must be a NUL-terminated type name.
    /// Does not return; the error longjmps to Lua's protected call.
    pub fn typeError(self: Args, n: usize, expected: [:0]const u8) noreturn {
        _ = c.luaL_typerror(self.state.raw, self.index(n), expected.ptr);
        unreachable;
    }

    fn index(self: Args, n: usize) Index {
        return self.base + @as(Index, @intCast(n)) - 1;
    }
};

/// A Lua on-stack string buffer; initialize it in place and do not copy it.
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

    /// Push accumulated bytes to the Lua stack; reinitialize before reuse.
    pub fn push(self: *Buffer) void {
        c.luaL_pushresult(&self.raw);
    }
};

/// LuaJIT compiler and profiler controls.
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

    /// Apply `mode` to a function, trace, or engine; false means the target is unavailable.
    /// `index` is ignored for the engine target.
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

    /// Start sampling with `callback` on the script thread.
    /// The callback must not call back into `state`.
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

    /// Return the profiler's stack dump as borrowed bytes.
    pub fn profileDumpStack(state: *const State, format: [:0]const u8, depth: Index) Borrowed {
        var length: usize = 0;
        const text = c.luaJIT_profile_dumpstack(state.raw, format.ptr, depth, &length) orelse
            return .{ .ptr = &[_]u8{}, .len = 0 };
        return .{ .ptr = text, .len = length };
    }
};
