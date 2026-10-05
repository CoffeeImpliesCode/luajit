// SPDX-License-Identifier: MIT
//
//! Consumes the `luajit` package the way an outside project would.
//!
//! Everything here goes through the published surface only: `dep.module` in
//! `build.zig`, and `@import("luajit")` here. No path reaches into the library's
//! own tree, so if this builds and produces the answers below, the module
//! contract is real.
//!
//! The answers are not values this program computed and printed for
//! comparison:
//!
//!  * `_VERSION` is checked against `luajit.c.LUA_VERSION`, which is the string
//!    the translated header carries. A header and a library that disagree would
//!    fail here, which is the property that matters for a Lua 5.1 ABI.
//!  * `jit.version_num` is checked against the 2.1 family range, because this
//!    package's declarations are LuaJIT 2.1's and nothing else's.
//!  * The sum of 1 to 1000 is 500500, and `string.format("%05d", 42)` is `00042`.
//!  * `ffi.sizeof` is checked against Zig's own `@sizeOf` for this build, and
//!    `ffi.C.abs(-7)` against the definition of `abs`.
//!  * The compiler's state is read back from `jit.status`, the library's own
//!    account of itself; its first result is that flag (`src/lib_jit.c:101-109`).
//!  * Every name `Library.globalNames` reports for a library this program uses
//!    is a table in the running state, and a Zig function registered from here
//!    is callable from a script with its arguments checked through `Args`.
//!  * The allocator figures are this program's own bookkeeping: it installs a
//!    counting allocator, and the closing line is only printed when every block
//!    the state allocated came back.
//!
//! Any mismatch prints both sides and exits non-zero.
//!
//! The same source builds against a linked package and against a
//! runtime-loaded one. `luajit.runtime_loaded` is a comptime constant, so the
//! difference is one branch and no duplicated program: in the runtime-loaded
//! build the provider is named on the command line (`--provider <path>`) or in
//! `LUAJIT_TEST_PROVIDER`, loaded once, and the same answers follow.

const std = @import("std");
const luajit = @import("luajit");

/// The sum of the first thousand positive integers.
const thousand_sum: luajit.Integer = 500500;

/// `"%05d"` of 42: five digits, zero padded.
const zero_padded = "00042";

/// The LuaJIT release family these declarations are. `LUAJIT_VERSION_NUM` is
/// 20199 for the 2.1 rolling header (`src/luajit_rolling.h:34`), so a 2.1 build
/// is in this range and a different major family is not.
const version_family_low: luajit.Integer = 20100;
const version_family_high: luajit.Integer = 30000;

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // In a runtime-loading build every call below goes through a table that this
    // one call fills. In a linked build the branch is not analyzed at all.
    if (comptime luajit.runtime_loaded) {
        try luajit.load(.{ .path = try providerRequest(init) });
        try w.print("luajit consumer: loaded {s}\n", .{luajit.loadedSource().?.path});
    } else {
        try w.print("luajit consumer: linked\n", .{});
    }

    // The raw route is reachable from the same import, which is what makes the
    // escape hatch usable without a second dependency.
    try w.print("headers say: lua {s}, luajit {s}\n", .{
        luajit.c.LUA_VERSION,
        luajit.c.LUAJIT_VERSION,
    });

    var budget = Budget{ .allocator = std.heap.page_allocator };
    defer budget.deinit();

    var state = try luajit.State.initWithAllocator(&budgetAlloc, &budget);
    state.openLibs();
    // Ownership: the state is closed at the end of this function, and the
    // closing check below is only reachable if everything it took came back.
    defer state.deinit();

    // `luaL_openlibs` preloads the FFI for `require` (`src/lib_init.c:32-36`)
    // and `luaopen_ffi` registers no global of its own ("Note: no global \"ffi\"
    // created!", `src/lib_ffi.c:855`), so the `ffi` global the checks below
    // read is one this SDK named. Opened once, here, before anything else
    // uses it.
    state.openFfi();

    // The library reports the same release the header does.
    try state.run("return _VERSION, jit.version, jit.version_num", "=consumer");
    try expectText(w, "state", "_VERSION", state.toString(1), luajit.c.LUA_VERSION);
    try expectText(w, "state", "jit.version", state.toString(2), luajit.c.LUAJIT_VERSION);

    const version_num = state.toInteger(3);
    if (version_num < version_family_low or version_num >= version_family_high) {
        try w.print("jit.version_num {d} is outside the 2.1 family\n", .{version_num});
        return error.ConsumerCheckFailed;
    }
    try w.print("{s: <24} in the 2.1 family\n", .{ "jit.version_num" });

    // Protected chunk evaluation, with results read back off the stack.
    state.setTop(0);
    try state.run(
        \\local s = 0
        \\for i = 1, 1000 do s = s + i end
        \\return s, string.format("%05d", 42), ("luajit"):upper()
    , "=consumer");
    try expectInteger(w, "stack", "sum of 1..1000", state.toInteger(1), thousand_sum);
    try expectText(w, "stack", "string.format", state.toString(2), zero_padded);
    try expectText(w, "stack", "('luajit'):upper()", state.toString(3), "LUAJIT");

    // A stack value built from Zig and read back through the same API.
    state.setTop(0);
    state.newTable();
    const table: luajit.Index = @intCast(state.top());
    state.pushInteger(7);
    state.rawSetI(table, 1);
    state.pushString("answer");
    state.setField(table, "what");
    state.getField(table, "what");
    try expectText(w, "table field", "t.what", state.toString(-1), "answer");
    state.pop(1);
    state.rawGetI(table, 1);
    try expectInteger(w, "table item", "t[1]", state.toInteger(-1), 7);
    state.pop(1);
    state.pop(1);

    // The library names this SDK reports are the globals the running state
    // actually has. `run` calls a chunk with no arguments at all, so a chunk
    // that needs one is loaded and called through `call`; `rawget` on a table
    // with a string key cannot raise, which is what makes the unprotected call
    // the right one here.
    for ([_]luajit.Library{ .base, .package, .table, .string, .math }) |library| {
        for (library.globalNames()) |name| {
            state.setTop(0);
            try state.load("return rawget(_G, ...)", "=consumer");
            state.pushString(name);
            state.call(1, 1);
            const found = state.typeName(1);
            try w.print("{s: <9} {s: <24} {s}\n", .{ "globals", name, found });
            if (!state.isTable(1)) {
                std.debug.print("{s}: expected table, got {s}\n", .{ name, found });
                return error.ConsumerCheckFailed;
            }
        }
    }
    state.setTop(0);

    // A Zig function is callable from a script through the same published
    // surface, and reads its argument by number: `Args` adds `base + n - 1`,
    // and the base is 1 because that frame holds this call's arguments.
    state.pushCFunction(&zigDouble);
    state.setGlobal("zig_double");
    state.setTop(0);
    try state.run("return zig_double(21)", "=consumer");
    try expectInteger(w, "zig callback", "zig_double(21)", state.toInteger(1), 42);

    // The same function given the wrong type raises through that check, and
    // the protected call turns the raise into an error value.
    state.setTop(0);
    //
    // `run` answers `RunError!void` (`zig/root.zig:1149-1152`): the failure is
    // one of `RunError` and the success is nothing at all, so the two halves
    // are named here instead of by a `catch` whose arm would have to name a
    // `void`. A chunk that ran where this one has to raise is a check that did
    // not match, which is the error the next line already reports for every
    // other outcome.
    const callback_failure: luajit.RunError = if (state.run("return zig_double('x')", "=consumer")) |_|
        return error.ConsumerCheckFailed
    else |err|
        err;
    if (callback_failure != luajit.RunError.RuntimeError) return error.ConsumerCheckFailed;
    try w.print("{s: <9} {s: <24} {t}\n", .{ "callback", "wrong type", callback_failure });

    // An error is a returned value with a readable message, not an unwind.
    state.setTop(0);
    const failure: luajit.RunError = if (state.run("error('consumer check')", "=consumer")) |_|
        return error.ConsumerCheckFailed
    else |err|
        err;
    try w.print("{s: <24} {t}\n", .{ "protected call", failure });
    if (failure != luajit.RunError.RuntimeError) return error.ConsumerCheckFailed;
    const message = state.errorMessage();
    try w.print("{s: <24} {s}\n", .{ "  message", message.slice() });
    if (!std.mem.startsWith(u8, message.slice(), "consumer:1:")) {
        return error.ConsumerCheckFailed;
    }

    // The compiler is switched off and on through the typed entry points, and
    // the library's own `jit.status` says which state it ended up in. The stack
    // is cleared between the two: a protected call leaves what it returned
    // above what was already there, so reading index 1 after the second run
    // without clearing would be reading the first run's answer.
    state.setTop(0);
    if (!luajit.jit.disable(&state)) return error.ConsumerCheckFailed;
    try state.run("local on = jit.status() return on", "=consumer");
    if (state.toBoolean(1)) return error.ConsumerCheckFailed;
    state.setTop(0);
    if (!luajit.jit.enable(&state)) return error.ConsumerCheckFailed;
    try state.run("local on = jit.status() return on", "=consumer");
    if (!state.toBoolean(1)) return error.ConsumerCheckFailed;
    try w.print("{s: <24} off then on, confirmed by jit.status\n", .{ "jit engine" });

    // The FFI, which is what a LuaJIT build offers that a plain Lua 5.1 does
    // not. The `tonumber` around the call result is not decoration:
    // `lua_tointegerx` sets its flag only for a slot that already holds a
    // number or a string that scans as one, and answers 0 otherwise
    // (`src/lj_api.c:422-445`); a cdata is neither, so the conversion has to
    // happen in Lua where the cdata's `__tonumber` metamethod runs.
    //
    // A C symbol has to be declared before this build will index it:
    // `lj_clib_index` raises `LJ_ERR_FFI_NODECL` for a name no declaration
    // made (`src/lj_clib.c:348-350`, `src/lj_errmsg.h:177`), so there is no
    // implicit declaration to fall back on and the prototype glibc gives for
    // `abs` is written first. It is also what gives the call below an
    // argument type to convert to.
    state.setTop(0);
    try state.run("ffi.cdef[[ int abs(int); ]]", "=consumer");
    state.setTop(0);
    try state.run(
        \\return tonumber(ffi.sizeof("void*")), tonumber(ffi.C.abs(-7))
    , "=consumer");
    if (state.toInteger(1) != @as(luajit.Integer, @intCast(@sizeOf(usize)))) {
        return error.ConsumerCheckFailed;
    }
    try expectInteger(w, "ffi", "ffi.C.abs(-7)", state.toInteger(2), 7);

    // Close the state here rather than through the deferred close, so the
    // accounting below is about this program's own state and nothing else.
    state.deinit();
    if (budget.blocks.count() != 0 or budget.bytes_out != budget.bytes_in) {
        try w.print("state left {d} blocks and {d}/{d} bytes\n", .{
            budget.blocks.count(),
            budget.bytes_in,
            budget.bytes_out,
        });
        return error.ConsumerCheckFailed;
    }
    try w.print("{s: <24} every block returned ({d} bytes)\n", .{
        "allocator", budget.bytes_out,
    });

    try w.print("every check matched\n", .{});
    try w.flush();
}

fn expectText(
    w: *std.Io.Writer,
    origin: []const u8,
    what: []const u8,
    got: luajit.Borrowed,
    want: []const u8,
) !void {
    try w.print("{s: <9} {s: <24} {s}\n", .{ origin, what, got.slice() });
    if (!got.eql(want)) {
        std.debug.print("{s}: expected {s}, got {s}\n", .{ what, want, got.slice() });
        return error.ConsumerCheckFailed;
    }
}

fn expectInteger(
    w: *std.Io.Writer,
    origin: []const u8,
    what: []const u8,
    got: luajit.Integer,
    want: luajit.Integer,
) !void {
    try w.print("{s: <9} {s: <24} {d}\n", .{ origin, what, got });
    if (got != want) {
        std.debug.print("{s}: expected {d}, got {d}\n", .{ what, want, got });
        return error.ConsumerCheckFailed;
    }
}

/// The accounting side of the allocator this program installs.
///
/// The point of it is the closing line in `main`: a state that took a block and
/// did not give it back would leave an entry here, and the program would exit
/// non-zero instead of claiming a clean close.
const Budget = struct {
    allocator: std.mem.Allocator,
    blocks: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    bytes_out: usize = 0,
    bytes_in: usize = 0,

    fn deinit(self: *Budget) void {
        self.blocks.deinit(self.allocator);
    }
};

/// A block as the allocator that owns it, and the alignment every block this
/// allocator hands out has to satisfy.
///
/// LuaJIT stores its own objects in these blocks and their alignment is not 1:
/// `TValue` is declared `LJ_ALIGN(8)` (`src/lj_obj.h:174`) and `GCudata`
/// carries an `align1` field to force the same (`src/lj_obj.h:330`), so the
/// first object in a block at a lesser address would be misaligned. Zig's
/// `alloc(u8, n)` promises alignment 1 and nothing more, which is why a block
/// is asked for with this alignment and given back with the same one.
const Block = []align(8) u8;
const block_alignment: std.mem.Alignment = .@"8";

/// The allocator `lua_newstate` is given.
///
/// `src/lj_gc.c:869-881` is the contract this implements: a null `ptr` goes
/// with `osize == 0`, `nsize == 0` is the only request to release, and a
/// request for more than nothing must come back with a pointer or the library
/// raises on the spot. Every block is recorded by the address it was handed out
/// at and the size *this* allocator gave it, because Zig's `free` and `realloc`
/// want the size that was allocated rather than the one Lua accounts for, and
/// because that pair is what the closing check in `main` is about.
fn budgetAlloc(
    user_data: ?*anyopaque,
    pointer: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque {
    _ = osize;
    const self: *Budget = @ptrCast(@alignCast(user_data.?));

    if (nsize == 0) {
        if (pointer) |address| {
            const entry = self.blocks.fetchRemove(@intFromPtr(address)) orelse
                return null;
            self.allocator.free(blockAt(address, entry.value));
            self.bytes_in += entry.value;
        }
        return null;
    }

    if (pointer) |address| {
        // The old entry goes before the resize: the block may move, and an
        // entry left behind at the old address would be a block this allocator
        // no longer owns and could never release, so the closing check would
        // report a leak that is really a bookkeeping mistake here.
        const entry = self.blocks.fetchRemove(@intFromPtr(address)) orelse
            return null;
        const grown = self.allocator.realloc(blockAt(address, entry.value), nsize) catch {
            // The resize failed, so the block is still the one that was handed
            // out, at its original size, and it has to stay on the books.
            self.blocks.putAssumeCapacity(@intFromPtr(address), entry.value);
            return null;
        };
        self.blocks.putAssumeCapacity(@intFromPtr(grown.ptr), nsize);
        self.bytes_in += entry.value;
        self.bytes_out += nsize;
        return @ptrCast(grown.ptr);
    }

    const fresh = self.allocator.alignedAlloc(u8, block_alignment, nsize) catch
        return null;
    self.blocks.put(self.allocator, @intFromPtr(fresh.ptr), nsize) catch {
        self.allocator.free(fresh);
        return null;
    };
    self.bytes_out += nsize;
    return @ptrCast(fresh.ptr);
}

/// The recorded block at `address`, at the length it was handed out with, so
/// that `free` and `realloc` see the same alignment the allocation had.
///
/// The `@alignCast` is not a way to make a lesser address pass: an address
/// only reaches this from a `fetchRemove` on `blocks`, and every entry in
/// `blocks` was written by this allocator's own fresh-allocation arm, which
/// asks for `block_alignment`, or by the resize arm, which reallocs such a
/// block and therefore keeps its alignment. Anything else -- an address the
/// library never got from here -- misses the map and is answered with null
/// before this is reached. The cast states that invariant; in a checked build
/// it is still checked at run time.
fn blockAt(address: *anyopaque, length: usize) Block {
    return @as([*]align(8) u8, @ptrCast(@alignCast(address)))[0..length];
}

/// The C function `zig_double` is bound to: it reads one argument through
/// `Args` and leaves its double on the stack.
fn zigDouble(l: ?*luajit.c.lua_State) callconv(.c) c_int {
    var state = luajit.State{ .raw = l };
    const args = luajit.Args{ .state = &state, .base = 1 };
    state.pushInteger(args.checkInteger(1) * 2);
    return 1;
}

/// The provider this run should load, from `--provider <path>` or from
/// `LUAJIT_TEST_PROVIDER`.
///
/// Both are explicit. Nothing here looks in a default location, and a build
/// that was not told which file to load says so rather than loading something
/// else.
fn providerRequest(init: std.process.Init) ConfigurationError![]const u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch
        return noProvider();
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) {
            if (index + 1 >= args.len) return noProvider();
            return args[index + 1];
        }
    }
    return init.environ_map.get("LUAJIT_TEST_PROVIDER") orelse
        return noProvider();
}

/// Say which variable is missing. An error name on its own would send the next
/// person into the loader instead of to the command line.
fn noProvider() ConfigurationError {
    std.debug.print(
        "consumer: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export LUAJIT_TEST_PROVIDER with a shared object exporting the " ++
            "entry points of src/lua.h, src/lauxlib.h, src/lualib.h and the " ++
            "generated src/luajit.h. Nothing is loaded by default and no other " ++
            "file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}