// SPDX-License-Identifier: MIT
//! Exercises linked and runtime-loaded LuaJIT through the published `luajit` module.
//! Checks version, standard libraries, FFI layout, callbacks, and allocator cleanup.

const std = @import("std");
const luajit = @import("luajit");

const thousand_sum: luajit.Integer = 500500;

const zero_padded = "00042";

/// Bounds for LuaJIT 2.1's rolling `LUAJIT_VERSION_NUM`.
const version_family_low: luajit.Integer = 20100;
const version_family_high: luajit.Integer = 30000;

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // Runtime builds load the explicitly named provider before any native call.
    if (comptime luajit.runtime_loaded) {
        try luajit.load(.{ .path = try providerRequest(init) });
        try w.print("luajit consumer: loaded {s}\n", .{luajit.loadedSource().?.path});
    } else {
        try w.print("luajit consumer: linked\n", .{});
    }

    // The published module also exposes its raw translated declarations.
    try w.print("headers say: lua {s}, luajit {s}\n", .{
        luajit.c.LUA_VERSION,
        luajit.c.LUAJIT_VERSION,
    });

    var budget = Budget{ .allocator = std.heap.page_allocator };
    defer budget.deinit();

    var state = try luajit.State.initWithAllocator(&budgetAlloc, &budget);
    state.openLibs();
    // Defer cleanup on errors; the success path closes before checking allocator balances.
    defer state.deinit();

    // `openLibs` preloads FFI but does not create global `ffi`; open it explicitly.
    state.openFfi();

    try state.run("return _VERSION, jit.version, jit.version_num", "=consumer");
    try expectText(w, "state", "_VERSION", state.toString(1), luajit.c.LUA_VERSION);
    try expectText(w, "state", "jit.version", state.toString(2), luajit.c.LUAJIT_VERSION);

    const version_num = state.toInteger(3);
    if (version_num < version_family_low or version_num >= version_family_high) {
        try w.print("jit.version_num {d} is outside the 2.1 family\n", .{version_num});
        return error.ConsumerCheckFailed;
    }
    try w.print("{s: <24} in the 2.1 family\n", .{ "jit.version_num" });

    state.setTop(0);
    try state.run(
        \\local s = 0
        \\for i = 1, 1000 do s = s + i end
        \\return s, string.format("%05d", 42), ("luajit"):upper()
    , "=consumer");
    try expectInteger(w, "stack", "sum of 1..1000", state.toInteger(1), thousand_sum);
    try expectText(w, "stack", "string.format", state.toString(2), zero_padded);
    try expectText(w, "stack", "('luajit'):upper()", state.toString(3), "LUAJIT");

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

    // Check each reported library name against `_G` in the running state.
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

    // `Args` reads callback arguments from frame index 1.
    state.pushCFunction(&zigDouble);
    state.setGlobal("zig_double");
    state.setTop(0);
    try state.run("return zig_double(21)", "=consumer");
    try expectInteger(w, "zig callback", "zig_double(21)", state.toInteger(1), 42);

    // A wrong callback argument returns `RunError` through the protected call.
    state.setTop(0);
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

    // Clear the stack between runs so each `jit.status` result is read from index 1.
    state.setTop(0);
    if (!luajit.jit.disable(&state)) return error.ConsumerCheckFailed;
    try state.run("local on = jit.status() return on", "=consumer");
    if (state.toBoolean(1)) return error.ConsumerCheckFailed;
    state.setTop(0);
    if (!luajit.jit.enable(&state)) return error.ConsumerCheckFailed;
    try state.run("local on = jit.status() return on", "=consumer");
    if (!state.toBoolean(1)) return error.ConsumerCheckFailed;
    try w.print("{s: <24} off then on, confirmed by jit.status\n", .{ "jit engine" });

    // Convert FFI cdata with Lua's `tonumber`; `lua_tointegerx` accepts only numbers or numeric strings (`src/lj_api.c:422-445`).
    // Declare `abs` before `ffi.C` lookup; LuaJIT rejects undeclared symbols (`src/lj_clib.c:348-350`).
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

/// Counts Lua allocations so `main` can verify that closing the state freed every block.
const Budget = struct {
    allocator: std.mem.Allocator,
    blocks: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    bytes_out: usize = 0,
    bytes_in: usize = 0,

    fn deinit(self: *Budget) void {
        self.blocks.deinit(self.allocator);
    }
};

/// LuaJIT objects need 8-byte alignment; the allocator returns `align(8)` blocks (`src/lj_obj.h:174`).
const Block = []align(8) u8;
const block_alignment: std.mem.Alignment = .@"8";

/// Implements `lua_newstate`'s allocator contract: `nsize == 0` frees; allocation failure returns null.
/// Records addresses and sizes because Zig `free` and `realloc` require the original allocation size.
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
        // Remove the old address before `realloc`; it may move the block.
        const entry = self.blocks.fetchRemove(@intFromPtr(address)) orelse
            return null;
        const grown = self.allocator.realloc(blockAt(address, entry.value), nsize) catch {
            // On failure, retain the original block and its recorded size.
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

/// Reconstructs the recorded aligned block; only addresses removed from `Budget.blocks` reach here.
/// Fresh and resized blocks preserve `block_alignment`, so the cast is valid.
fn blockAt(address: *anyopaque, length: usize) Block {
    return @as([*]align(8) u8, @ptrCast(@alignCast(address)))[0..length];
}

/// C callback doubles its first integer argument and returns one Lua result.
fn zigDouble(l: ?*luajit.c.lua_State) callconv(.c) c_int {
    var state = luajit.State{ .raw = l };
    const args = luajit.Args{ .state = &state, .base = 1 };
    state.pushInteger(args.checkInteger(1) * 2);
    return 1;
}

/// Resolves `--provider <path>` or `LUAJIT_TEST_PROVIDER`; no default is used.
/// Returns the explicit path or `NoProviderConfigured`.
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
