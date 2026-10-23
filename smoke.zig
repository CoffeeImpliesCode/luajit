// SPDX-License-Identifier: MIT
//! Smoke-test the LuaJIT facade in linked and runtime-loading builds.

const std = @import("std");
const luajit = @import("luajit");

/// Missing required runtime provider path.
const ConfigurationError = error{NoProviderConfigured};

const thousand_sum: luajit.Integer = 500500;

/// `%.14g` formatting of one third.
const third_as_text = "0.33333333333333";

/// Expected result of formatting 42 and 1.5.
const formatted = "00042|1.50";

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // Runtime-loading builds require an explicit provider; linked builds do not.
    if (comptime luajit.runtime_loaded) {
        try luajit.load(.{ .path = try providerRequest(init) });
        try w.print("loaded provider: {s}\n", .{luajit.loadedSource().?.path});
    } else {
        try w.print("linked\n", .{});
    }

    // Read version strings from the translated headers.
    try w.print("headers: lua {s}, luajit {s}\n", .{
        luajit.c.LUA_VERSION,
        luajit.c.LUAJIT_VERSION,
    });

    var state = try luajit.State.init();
    defer state.deinit();
    state.openLibs();
    // `openFfi` installs the global; `openLibs` only preloads the module.
    state.openFfi();

    // Clear prior results so each chunk's return values start at stack index 1.

    try state.run("return _VERSION, jit.version", "=smoke");
    try checkText(w, "lua _VERSION", state.toString(1), luajit.c.LUA_VERSION);
    try checkText(w, "jit.version", state.toString(2), luajit.c.LUAJIT_VERSION);

    state.setTop(0);
    try state.run(
        \\local s = 0
        \\for i = 1, 1000 do s = s + i end
        \\return s,
        \\       tostring(1/3),
        \\       string.format("%05d|%.2f", 42, 1.5),
        \\       #("j" .. "it" .. "ing"),
        \\       ("abc"):upper()
    , "=smoke");
    try checkNumber(w, "sum of 1..1000", state.toNumber(1), thousand_sum);
    try checkText(w, "tostring(1/3)", state.toString(2), third_as_text);
    try checkText(w, "string.format", state.toString(3), formatted);
    // The concatenation has six characters.
    try checkNumber(w, "#(\"j\"..\"it\"..\"ing\")", state.toNumber(4), 6);
    try checkText(w, "('abc'):upper()", state.toString(5), "ABC");

    // `jit.status` returns the engine flag first (`src/lib_jit.c:101-109`).
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=smoke");
    try w.print("jit engine on at start: {}\n", .{state.toBoolean(1)});
    if (!state.toBoolean(1)) return error.EngineNotOn;

    if (!luajit.jit.disable(&state)) return error.JitDisableFailed;
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=smoke");
    try w.print("jit engine after jit.off(): {}\n", .{state.toBoolean(1)});
    if (state.toBoolean(1)) return error.JitStillOn;

    if (!luajit.jit.enable(&state)) return error.JitEnableFailed;
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=smoke");
    try w.print("jit engine after jit.on(): {}\n", .{state.toBoolean(1)});
    if (!state.toBoolean(1)) return error.JitStillOff;

    // Convert FFI cdata to Lua numbers before reading it through the C API.
    state.setTop(0);
    try state.run(
        \\return tonumber(ffi.sizeof("int")),
        \\       tonumber(ffi.sizeof("double")),
        \\       tonumber(ffi.sizeof("void*"))
    , "=smoke");
    const sizes_agree =
        state.toInteger(1) == @as(luajit.Integer, @intCast(@sizeOf(c_int))) and
        state.toInteger(2) == @as(luajit.Integer, @intCast(@sizeOf(f64))) and
        state.toInteger(3) == @as(luajit.Integer, @intCast(@sizeOf(usize)));
    try w.print("ffi sizes agree with this build: {}\n", .{sizes_agree});
    if (!sizes_agree) return error.FfiSizeMismatch;

    // A protected error is returned, and the state remains usable.
    state.setTop(0);
    const failure: luajit.RunError = if (state.run("error('deliberate')", "=smoke")) |_|
        return error.ExpectedRunFailure
    else |err|
        err;
    try w.print("protected call reports: {t}\n", .{failure});
    if (failure != luajit.RunError.RuntimeError) return error.UnexpectedRunError;
    try w.print("  message: {s}\n", .{state.errorMessage().slice()});
    state.setTop(0);

    try state.run("return 'still usable'", "=smoke");
    try checkText(w, "after the error", state.toString(1), "still usable");

    try w.print("every check above matched its stated answer\n", .{});
    try w.flush();
}

fn checkText(w: *std.Io.Writer, what: []const u8, got: luajit.Borrowed, want: [:0]const u8) !void {
    try w.print("{s: <28} {s}\n", .{ what, got.slice() });
    if (!got.eql(want)) {
        std.debug.print("{s}: expected {s}, got {s}\n", .{ what, want, got.slice() });
        return error.SmokeCheckFailed;
    }
}

fn checkNumber(
    w: *std.Io.Writer,
    what: []const u8,
    got: luajit.Number,
    want: luajit.Integer,
) !void {
    try w.print("{s: <28} {d}\n", .{ what, got });
    if (got != @as(luajit.Number, @floatFromInt(want))) {
        std.debug.print("{s}: expected {d}, got {d}\n", .{ what, want, got });
        return error.SmokeCheckFailed;
    }
}

/// Reads `--provider <path>` or `LUAJIT_TEST_PROVIDER`; no default is used.
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
        "smoke.zig: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export LUAJIT_TEST_PROVIDER with a shared object exporting the " ++
            "entry points of src/lua.h, src/lauxlib.h, src/lualib.h and the " ++
            "generated src/luajit.h. Nothing is loaded by default and no other " ++
            "file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}
