// SPDX-License-Identifier: MIT
//
//! A runnable, deterministic demonstration of the LuaJIT facade.
//!
//! `zig build smoke` runs this. There is no input to supply and nothing printed
//! below depends on the clock, a random seed, a path or the host: the values are
//! either fixed by the language, fixed by this repository's configuration
//! headers, or computed here and checked against an answer this file states.
//!
//! In a runtime-loading build the provider is named on the command line
//! (`--provider <path>`) or in `LUAJIT_TEST_PROVIDER`, and the program says
//! which configuration it is in the first line. In a linked build neither is
//! needed and neither is read.
//!
//! ## Where the answers come from
//!
//!  * The sum of 1 to 1000 is 500500, and a third is `0.33333333333333` because
//!    `LUA_NUMBER_FMT` is `%.14g` (`src/luaconf.h:122`).
//!  * `string.format("%05d|%.2f", 42, 1.5)` is `00042|1.50` by the definition of
//!    the two conversions, in C as in Lua.
//!  * The compiler's on/off state is read back from `jit.status`, which is
//!    the library's own account of itself (`src/lib_jit.c:101-109`) and whose
//!    *first* result is that flag, and the calls that change it report success
//!    as `1` (`src/lj_dispatch.c:326`).
//!  * The FFI's idea of the sizes of `int`, `double` and `void *` is compared
//!    with Zig's `@sizeOf` for this build, and only the agreement is printed, so
//!    the line is the same on a 32-bit and a 64-bit target.
//!
//! Every check prints both sides and exits non-zero on a mismatch, so this is a
//! check and not a demo.

const std = @import("std");
const luajit = @import("luajit");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// The sum of the first thousand positive integers.
const thousand_sum: luajit.Integer = 500500;

/// `LUA_NUMBER_FMT` is `%.14g` (`src/luaconf.h:122`), so this is the whole
/// answer and no more digits follow.
const third_as_text = "0.33333333333333";

/// What `"%05d|%.2f"` applied to 42 and 1.5 must produce.
const formatted = "00042|1.50";

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // In a runtime-loading build every call below goes through a table that this
    // one call fills. In a linked build the branch is not analyzed at all.
    if (comptime luajit.runtime_loaded) {
        try luajit.load(.{ .path = try providerRequest(init) });
        try w.print("loaded provider: {s}\n", .{luajit.loadedSource().?.path});
    } else {
        try w.print("linked\n", .{});
    }

    // Through the raw route, so these two lines name the headers this build
    // translated rather than constants written here.
    try w.print("headers: lua {s}, luajit {s}\n", .{
        luajit.c.LUA_VERSION,
        luajit.c.LUAJIT_VERSION,
    });

    var state = try luajit.State.init();
    defer state.deinit();
    state.openLibs();
    // Opened once, here, where nothing has used the FFI yet. `luaL_openlibs`
    // only preloads it for `require` (`src/lib_init.c:32-36`) and `luaopen_ffi`
    // creates no global of its own (`src/lib_ffi.c:855`), so the global the
    // check further down reads is one this facade named.
    state.openFfi();

    // Every chunk below starts from an empty stack. A protected call leaves
    // what the chunk returned above whatever was already there, so index 1 is
    // this chunk's own answer only when nothing was underneath it. Without the
    // clear, the second check in this program would be reading the first
    // chunk's `_VERSION` and printing the right answer for the wrong reason.

    // Through Lua, so the versions above are confirmed by the library that is
    // actually running rather than by the translation alone.
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
    // "j" .. "it" .. "ing" is "jiting": six characters, one from the first
    // literal and two from each of the other two. `#` counts them.
    try checkNumber(w, "#(\"j\"..\"it\"..\"ing\")", state.toNumber(4), 6);
    try checkText(w, "('abc'):upper()", state.toString(5), "ABC");

    // The compiler's own account of itself, before and after this program
    // switches it off and back on. `jit.status()` answers with several values
    // and the flag is the first of them (`src/lib_jit.c:101-109`), so it is
    // bound before it is returned: `return f()` keeps only the last one.
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

    // The FFI's view of this target's types, against Zig's own. Only the
    // agreement is printed, so the line does not change with the pointer width.
    //
    // `tonumber` around each `ffi.sizeof` is not decoration:
    // `lua_tonumberx` sets its flag only for a slot that already holds a
    // number or a string that scans as one, and answers 0 otherwise
    // (`src/lj_api.c:363-377`); a cdata is neither, so the conversion has to
    // happen in Lua where the cdata's `__tonumber` metamethod runs.
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

    // `run` answers the failure, and the answer is an error value rather than
    // an unwind: the message is left on the stack and the state is still
    // usable, which is what a caller embedding a script it did not write needs.
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

/// Print one answer and fail if it is not the expected one.
fn checkText(w: *std.Io.Writer, what: []const u8, got: luajit.Borrowed, want: [:0]const u8) !void {
    try w.print("{s: <28} {s}\n", .{ what, got.slice() });
    if (!got.eql(want)) {
        std.debug.print("{s}: expected {s}, got {s}\n", .{ what, want, got.slice() });
        return error.SmokeCheckFailed;
    }
}

/// Print one answer and fail if it is not the expected one.
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
        "smoke.zig: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export LUAJIT_TEST_PROVIDER with a shared object exporting the " ++
            "entry points of src/lua.h, src/lauxlib.h, src/lualib.h and the " ++
            "generated src/luajit.h. Nothing is loaded by default and no other " ++
            "file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}