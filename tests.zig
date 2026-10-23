// SPDX-License-Identifier: MIT

//! LuaJIT facade behavior tests.
const std = @import("std");
const luajit = @import("luajit");
const testing = std.testing;

/// Shared-object path for runtime-loading tests.
const provider_variable = "LUAJIT_TEST_PROVIDER";

/// Load the configured runtime provider once; linked builds need no load.
fn nativeReady() void {
    if (comptime !luajit.runtime_loaded) return;
    if (luajit.loadedSource() != null) return;

    var buffer: [4096]u8 = undefined;
    const value = std.testing.environ.getAlloc(testing.allocator, provider_variable) catch
        missingProvider();
    defer testing.allocator.free(value);
    if (value.len == 0 or value.len > buffer.len) missingProvider();
    @memcpy(buffer[0..value.len], value);
    luajit.load(.{ .path = buffer[0..value.len] }) catch |err| {
        std.debug.print(
            "tests.zig: loading " ++ provider_variable ++ " = \"{s}\" failed: {t}\n",
            .{ buffer[0..value.len], err },
        );
        @panic("tests.zig: the provider named by " ++ provider_variable ++
            " did not load; nothing below this line ran");
    };
}

fn missingProvider() noreturn {
    @panic(
        "tests.zig: this is a runtime-loading build and " ++ provider_variable ++
            " is not set. Point it at a shared object exporting the entry " ++
            "points of src/lua.h, src/lauxlib.h, src/lualib.h and the " ++
            "generated src/luajit.h -- for example the one `zig build " ++
            "-Dlinkage=dynamic` installs -- and export it for the whole " ++
            "`zig build` invocation: the build cannot inject a path into a " ++
            "run step's environment.",
    );
}

/// Open a state with standard libraries.
fn openState() luajit.State {
    nativeReady();
    var state = luajit.State.init() catch @panic("tests.zig: no Lua state; the " ++
        "allocator could not provide one");
    state.openLibs();
    return state;
}

/// Open a state without libraries.
fn bareState() luajit.State {
    nativeReady();
    return luajit.State.init() catch @panic("tests.zig: no Lua state; the " ++
        "allocator could not provide one");
}

/// Run a chunk and report unexpected Lua errors with the stack message.
fn runReporting(
    state: *luajit.State,
    source: []const u8,
    chunk_name: ?[*:0]const u8,
    expected: ?luajit.RunError,
) luajit.RunError!void {
    state.load(source, chunk_name) catch |err| {
        reportUnexpected(state, err, expected);
        return err;
    };
    state.protectedCall(0, luajit.multret) catch |err| {
        reportUnexpected(state, err, expected);
        return err;
    };
}

/// Print the expected status and Lua's error message.
fn reportUnexpected(
    state: *const luajit.State,
    got: luajit.RunError,
    expected: ?luajit.RunError,
) void {
    if (expected) |want| {
        if (got == want) return;
    }
    const wanted = if (expected) |want| @errorName(want) else "the chunk to succeed";
    std.debug.print(
        "\ntests.zig: wanted {s}, the chunk reported {t}\n  message: {s}\n",
        .{ wanted, got, state.errorMessage().slice() },
    );
}

test "a chunk's results arrive on the stack in order" {
    var state = openState();
    defer state.deinit();

    try testing.expectEqual(@as(usize, 0), state.top());
    try state.run("return 6 * 7, 'seven', true", "=results");
    try testing.expectEqual(@as(usize, 3), state.top());

    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNUMBER), state.typeOf(1));
    try testing.expectEqual(@as(luajit.Integer, 42), state.toInteger(1));

    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TSTRING), state.typeOf(2));
    try testing.expect(state.toString(2).eql("seven"));

    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TBOOLEAN), state.typeOf(3));
    try testing.expect(state.toBoolean(3));

    state.setTop(0);
    try state.run("return type(6 * 7)", "=type");
    try testing.expect(state.toString(1).eql("number"));
}

test "a chunk that raises is answered, and the state still works afterwards" {
    var state = openState();
    defer state.deinit();

    try testing.expectError(
        error.RuntimeError,
        state.run("error('boom')", "=probe"),
    );
    const message = state.errorMessage();
    try testing.expect(std.mem.startsWith(u8, message.slice(), "probe:1:"));
    try testing.expect(std.mem.indexOf(u8, message.slice(), "boom") != null);

    state.setTop(0);
    try state.run("return 'still here'", "=after");
    try testing.expect(state.toString(1).eql("still here"));
}

test "a protected call returns the results it was asked for and disposes the rest" {
    var state = openState();
    defer state.deinit();

    try state.load("return 'first', 'second', 'third'", "=count");
    try state.protectedCall(0, 1);
    try testing.expectEqual(@as(usize, 1), state.top());
    try testing.expect(state.toString(1).eql("first"));

    state.setTop(0);
    try state.load("return 1, 2, 3", "=count");
    try state.protectedCall(0, 0);
    try testing.expectEqual(@as(usize, 0), state.top());

    state.setTop(0);
    try state.load("return 'only'", "=count");
    try state.protectedCall(0, 3);
    try testing.expectEqual(@as(usize, 3), state.top());
    try testing.expect(state.toString(1).eql("only"));
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(2));
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(3));

    state.setTop(0);
    try state.load("return 10, 20, 30", "=count");
    try state.protectedCall(0, luajit.multret);
    try testing.expectEqual(@as(usize, 3), state.top());
    try testing.expectEqual(@as(luajit.Integer, 30), state.toInteger(3));

    state.setTop(0);
    try state.load("local a, b = ... return a - b", "=args");
    state.pushNumber(10);
    state.pushNumber(4);
    try state.protectedCall(2, 1);
    try testing.expectEqual(@as(usize, 1), state.top());
    try testing.expectEqual(@as(luajit.Integer, 6), state.toInteger(1));
}

test "a failed protected call leaves the error object and nothing else moved" {
    var state = openState();
    defer state.deinit();

    state.pushString("below");
    try state.load("error('raised')", "=fail");
    try testing.expectError(
        error.RuntimeError,
        state.protectedCall(0, luajit.multret),
    );
    try testing.expectEqual(@as(usize, 2), state.top());
    try testing.expect(state.toString(1).eql("below"));

    const message = state.errorMessage();
    try testing.expect(std.mem.startsWith(u8, message.slice(), "fail:1:"));
    try testing.expect(state.errorMessage().eql(message.slice()));

    state.setTop(0);
    try state.run("return 'after the failure'", "=after");
    try testing.expectEqual(@as(usize, 1), state.top());
    try testing.expect(state.toString(1).eql("after the failure"));
}

test "a chunk that does not parse is a syntax error, and says where" {
    var state = openState();
    defer state.deinit();

    try testing.expectError(
        error.SyntaxError,
        state.run("return 1 +", "=probe"),
    );
    try testing.expect(std.mem.startsWith(
        u8,
        state.errorMessage().slice(),
        "probe:1:",
    ));
}

test "a string read as a number answers with that number's value" {
    var state = bareState();
    defer state.deinit();

    state.pushString("42");
    try testing.expectEqual(@as(?luajit.Integer, 42), state.toIntegerX(1));
    try testing.expectEqual(@as(?luajit.Number, 42), state.toNumberX(1));

    state.setTop(0);
    state.pushString("3.5");
    try testing.expectEqual(@as(?luajit.Integer, 3), state.toIntegerX(1));
    try testing.expectEqual(@as(?luajit.Number, 3.5), state.toNumberX(1));

    state.setTop(0);
    state.pushString("not a number");
    try testing.expectEqual(@as(?luajit.Integer, null), state.toIntegerX(1));
    try testing.expectEqual(@as(?luajit.Number, null), state.toNumberX(1));

    state.setTop(0);
    state.pushString("42abc");
    try testing.expectEqual(@as(?luajit.Integer, null), state.toIntegerX(1));
    try testing.expectEqual(@as(?luajit.Number, null), state.toNumberX(1));

    state.setTop(0);
    state.newTable();
    try testing.expectEqual(@as(?luajit.Integer, null), state.toIntegerX(1));
}

test "a number is a double, so 2^53 + 1 answers as 2^53" {
    const exact = std.math.cast(luajit.Integer, @as(i64, 1) << 53) orelse
        return error.SkipZigTest;
    const past = exact + 1;

    const as_number: luajit.Number = @floatFromInt(exact);
    try testing.expectEqual(@as(luajit.Number, 9007199254740992.0), as_number);
    try testing.expectEqual(as_number, @as(luajit.Number, @floatFromInt(past)));

    var state = bareState();
    defer state.deinit();

    state.pushInteger(exact);
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNUMBER), state.typeOf(1));
    try testing.expectEqual(@as(?luajit.Integer, exact), state.toIntegerX(1));
    try testing.expectEqual(exact, state.toInteger(1));

    state.setTop(0);
    state.pushInteger(past);
    try testing.expectEqual(@as(?luajit.Integer, exact), state.toIntegerX(1));
    try testing.expectEqual(exact, state.toInteger(1));

    state.setTop(0);
    state.pushString("9007199254740993");
    try testing.expectEqual(@as(?luajit.Integer, exact), state.toIntegerX(1));
    try testing.expectEqual(@as(?luajit.Number, as_number), state.toNumberX(1));

    state.setTop(0);
    state.pushString("9007199254740992");
    try testing.expectEqual(@as(?luajit.Integer, exact), state.toIntegerX(1));
    try testing.expectEqual(@as(?luajit.Number, as_number), state.toNumberX(1));
}

test "a double is formatted the way the configuration header says" {
    var state = openState();
    defer state.deinit();

    try state.run("return tostring(1/3)", "=format");
    try testing.expect(state.toString(1).eql("0.33333333333333"));

    state.setTop(0);
    try state.run("return tostring(0.5), tostring(100)", "=format");
    try testing.expect(state.toString(1).eql("0.5"));
    try testing.expect(state.toString(2).eql("100"));
}

test "toString converts the slot it reads" {
    var state = bareState();
    defer state.deinit();

    state.pushNumber(42);
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNUMBER), state.typeOf(1));
    try testing.expect(state.toString(1).eql("42"));
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TSTRING), state.typeOf(1));
}

test "the standard libraries answer" {
    var state = openState();
    defer state.deinit();

    try state.run(
        \\return string.format("%05d|%.2f", 42, 1.5),
        \\       string.rep("ab", 3, "-"),
        \\       table.concat({ "a", "b", "c" }, "+"),
        \\       math.floor(-1.5),
        \\       math.max(3, 7)
    , "=libs");
    try testing.expect(state.toString(1).eql("00042|1.50"));
    try testing.expect(state.toString(2).eql("ab-ab-ab"));
    try testing.expect(state.toString(3).eql("a+b+c"));
    try testing.expectEqual(@as(luajit.Number, -2), state.toNumber(4));
    try testing.expectEqual(@as(luajit.Number, 7), state.toNumber(5));
}

test "one library can be opened without opening all of them" {
    var state = bareState();
    defer state.deinit();

    try testing.expectEqual(@as(usize, 0), state.top());
    luajit.Library.base.open(&state);
    luajit.Library.math.open(&state);

    try testing.expectEqual(@as(usize, 0), state.top());
    try state.run("return math.floor(3.7), math.pi > 3", "=one");
    try testing.expectEqual(@as(luajit.Number, 3), state.toNumber(1));
    try testing.expect(state.toBoolean(2));

    state.setTop(0);
    try state.run("return io, os, coroutine", "=one");
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(1));
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(2));

    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TTABLE), state.typeOf(3));
}

test "every library opens and answers a known result" {
    nativeReady();

    // Call from a Lua frame; `luaopen_package` requires one (`src/lib_package.c:601`).

    const expected_jit_arch = jitArchName() orelse return error.SkipZigTest;
    const openers = [_]struct {
        name: []const u8,
        opener: luajit.c.lua_CFunction,
        probe: []const u8,
        expected: []const u8,
        // Call returned functions before reading their result.
        call_result: bool = false,
    }{
        .{
            .name = "base",
            .opener = luajit.c.luaopen_base,
            .probe = "return tostring(coroutine.wrap(function() return 6 * 7 end)())",
            .expected = "42",
        },
        .{
            .name = "package",
            .opener = luajit.c.luaopen_package,
            .probe = "package.preload.own = function() return 6 * 7 end return tostring(require(\"own\"))",
            .expected = "42",
        },
        .{
            .name = "table",
            .opener = luajit.c.luaopen_table,
            .probe = "return table.concat({ \"a\", \"b\", \"c\" }, \"+\")",
            .expected = "a+b+c",
        },
        .{
            .name = "io",
            .opener = luajit.c.luaopen_io,
            .probe = "return io.type(io.stdout)",
            .expected = "file",
        },
        .{
            .name = "os",
            .opener = luajit.c.luaopen_os,
            .probe = "return os.date(\"!%Y\", 0)",
            .expected = "1970",
        },
        .{
            .name = "string",
            .opener = luajit.c.luaopen_string,
            .probe = "return string.format(\"%05d\", 42)",
            .expected = "00042",
        },
        .{
            .name = "math",
            .opener = luajit.c.luaopen_math,
            .probe = "return tostring(math.floor(-1.5))",
            .expected = "-2",
        },
        // Query `debug.getinfo` from a Lua function, not a main chunk.
        .{
            .name = "debug",
            .opener = luajit.c.luaopen_debug,
            .probe = "return function() return debug.getinfo(1).what end",
            .expected = "Lua",
            .call_result = true,
        },
        .{
            .name = "bit",
            .opener = luajit.c.luaopen_bit,
            .probe = "return tostring(bit.band(0xff00, 0x0ff0))",
            .expected = "3840",
        },
        // Derive LuaJIT's architecture name from this binary's target.
        .{
            .name = "jit",
            .opener = luajit.c.luaopen_jit,
            .probe = "return jit.arch",
            .expected = expected_jit_arch,
        },
    };
    for (openers) |entry| {
        var state = bareState();
        defer state.deinit();
        // Open base first because the other libraries register into it.
        if (entry.opener != luajit.c.luaopen_base) luajit.Library.base.open(&state);
        state.pushCFunction(&openLibraryThroughCall);
        state.setGlobal("open_library");
        state.pushCFunction(entry.opener);
        state.pushString("");
        try state.load("return open_library()", "=open");
        try state.protectedCall(2, 0);
        if (state.top() != 0) {
            std.debug.print(
                "\ntests.zig: {s}: the opener left {d} value(s) on the stack, " ++
                    "so the probe's answer cannot be read from index 1\n",
                .{ entry.name, state.top() },
            );
            return error.ProbeStackNotEmpty;
        }

        state.load(entry.probe, "=probe") catch |err| {
            std.debug.print(
                "\ntests.zig: {s}: the probe did not parse ({t})\n  probe: {s}\n  message: {s}\n",
                .{ entry.name, err, entry.probe, state.errorMessage().slice() },
            );
            return error.ProbeDidNotParse;
        };
        state.protectedCall(0, 1) catch |err| {
            std.debug.print(
                "\ntests.zig: {s}: the probe raised ({t})\n  probe: {s}\n  message: {s}\n",
                .{ entry.name, err, entry.probe, state.errorMessage().slice() },
            );
            return error.ProbeRaised;
        };

        if (entry.call_result) {
            state.protectedCall(0, 1) catch |err| {
                std.debug.print(
                    "\ntests.zig: {s}: the returned function raised ({t})\n" ++
                        "  probe: {s}\n  message: {s}\n",
                    .{ entry.name, err, entry.probe, state.errorMessage().slice() },
                );
                return error.ProbeRaised;
            };
        }

        // Read the Lua type first; `toString` can convert the slot in place.
        const lua_type = state.typeName(1);
        const actual = state.toString(1);
        if (!actual.eql(entry.expected)) {
            std.debug.print(
                "\ntests.zig: {s}: the probe did not answer as derived\n" ++
                    "  probe:    {s}\n  expected: {s}\n  actual:   {s}\n" ++
                    "  lua type: {s}\n",
                .{ entry.name, entry.probe, entry.expected, actual.slice(), lua_type },
            );
            return error.ProbeAnswerMismatch;
        }
        state.setTop(0);
    }
}

/// Use LuaJIT's `LJ_ARCH_NAME` spelling; return null when unsupported.
fn jitArchName() ?[]const u8 {
    // Match byte-order tags separately; LuaJIT includes endianness (`src/lj_arch.h:326-328`).
    return switch (@import("builtin").target.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x64",
        .arm, .armeb, .thumb, .thumbeb => "arm",
        .aarch64 => "arm64",
        .aarch64_be => "arm64be",
        .powerpc => "ppc",
        .powerpc64 => "ppc64",
        .powerpc64le => "ppc64le",
        .mips => "mips",
        .mipsel => "mipsel",
        .mips64 => "mips64",
        .mips64el => "mips64el",
        else => null,
    };
}

/// Invoke with a Lua frame; `luaopen_package` needs `LUA_ENVIRONINDEX` (`src/lib_package.c:601`).
fn openLibraryThroughCall(l: ?*luajit.c.lua_State) callconv(.c) c_int {
    var state = luajit.State{ .raw = l };
    const opener = luajit.c.lua_tocfunction(l.?, 1) orelse return 0;
    // Copy before pushing, which may collect the stack string.
    var name_buffer: [64]u8 = undefined;
    const name = state.toString(2);
    if (name.len >= name_buffer.len) return 0;
    @memcpy(name_buffer[0..name.len], name.slice());
    name_buffer[name.len] = 0;
    state.pushString(name_buffer[0..name.len]);
    _ = opener(l.?);
    return 0;
}

test "upstream installs no global for the FFI or the string buffer" {
    var state = bareState();
    defer state.deinit();

    // `luaL_openlibs` preloads FFI and string.buffer but installs neither global.

    state.openLibs();
    try state.run(
        \\return rawget(_G, "ffi"), rawget(string, "buffer")
    , "=global");
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(1));
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(2));

    // FFI is available through `require`, not as a global.
    state.setTop(0);
    try state.run(
        \\return package.loaded.ffi == nil, type(require("ffi"))
    , "=global");
    try testing.expect(state.toBoolean(1));
    try testing.expect(state.toString(2).eql("table"));
}

test "a string with an embedded NUL survives a round trip" {
    var state = bareState();
    defer state.deinit();

    const text = "ab\x00cd";
    state.pushString(text);
    try testing.expectEqual(@as(usize, 5), state.lengthOf(1));
    try testing.expectEqualSlices(u8, text, state.toString(1).slice());

    // The C-string API stops at the first embedded NUL.
    state.setTop(0);
    luajit.c.lua_pushstring(state.raw, text);
    try testing.expectEqual(@as(usize, 2), state.lengthOf(1));
}

test "an on-stack buffer builds the same string without concatenating" {
    var state = bareState();
    defer state.deinit();

    var buffer: luajit.Buffer = .{};
    buffer.init(&state);
    buffer.add("ab");
    buffer.add("\x00cd");
    buffer.push();

    try testing.expectEqual(@as(usize, 5), state.lengthOf(1));
    try testing.expectEqualSlices(u8, "ab\x00cd", state.toString(1).slice());
}

test "a referenced value is still there after a collection, and unref releases it" {
    var state = bareState();
    defer state.deinit();

    // The registry reference keeps the table alive after it leaves the stack.
    state.newTable();
    const reference = state.ref(luajit.c.LUA_REGISTRYINDEX);
    try testing.expect(reference > 0); // neither LUA_REFNIL nor LUA_NOREF
    try testing.expectEqual(@as(usize, 0), state.top()); // ref popped the value

    state.collect();
    luajit.c.lua_rawgeti(state.raw, luajit.c.LUA_REGISTRYINDEX, reference);
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TTABLE), state.typeOf(-1));
    state.setTop(0);

    // `unref` removes the registry reference, allowing collection.
    state.unref(luajit.c.LUA_REGISTRYINDEX, reference);
    state.collect();
    luajit.c.lua_rawgeti(state.raw, luajit.c.LUA_REGISTRYINDEX, reference);
    try testing.expect(state.typeOf(-1) != luajit.c.LUA_TTABLE);
}

test "a table built from Zig reads back through the same API" {
    var state = bareState();
    defer state.deinit();

    state.newTable();
    const table: luajit.Index = @intCast(state.top());

    state.pushInteger(10);
    state.rawSetI(table, 1);
    state.pushString("named");
    state.setField(table, "key");

    try testing.expectEqual(@as(usize, 1), state.top()); // the table itself

    state.rawGetI(table, 1);
    try testing.expectEqual(@as(luajit.Integer, 10), state.toInteger(-1));
    state.pop(1);

    state.getField(table, "key");
    try testing.expect(state.toString(-1).eql("named"));
    state.pop(1);

    // Keep the key for the next call; `nextIsValid` leaves key and value on the stack.
    state.pushNil(1);
    var entries: usize = 0;
    while (state.nextIsValid(table)) {
        entries += 1;
        state.pop(1); // drop the value, keep the key for the next call
    }
    try testing.expectEqual(@as(usize, 1), state.top()); // the table alone
    try testing.expectEqual(@as(usize, 2), entries);
}

test "a Zig function is callable from Lua and checks its own arguments" {
    var state = openState();
    defer state.deinit();

    state.pushCFunction(&doubleArgument);
    state.setGlobal("double_it");

    try state.run("return double_it(21)", "=callback");
    try testing.expectEqual(@as(luajit.Integer, 42), state.toInteger(1));

    // Wrong argument types return a protected-call error; Lua's message text is not pinned.
    state.setTop(0);
    try testing.expectError(
        error.RuntimeError,
        runReporting(&state, "return double_it('not a number')", "=callback", error.RuntimeError),
    );

    // Subtraction makes argument order observable.
    state.setTop(0);
    state.pushCFunction(&subtractArguments);
    state.setGlobal("take_two");
    try state.run("return take_two(20, 22)", "=callback");
    try testing.expectEqual(@as(luajit.Integer, -2), state.toInteger(1));

    state.setTop(0);
    try state.run("return take_two(22, 20)", "=callback");
    try testing.expectEqual(@as(luajit.Integer, 2), state.toInteger(1));

    state.setTop(0);
    try state.run("return take_two(1, 2, 1000)", "=callback");
    try testing.expectEqual(@as(luajit.Integer, -1), state.toInteger(1));
}

/// Lua C callback that subtracts arguments 1 and 2 through `Args`.
fn subtractArguments(l: ?*luajit.c.lua_State) callconv(.c) c_int {
    var state = luajit.State{ .raw = l };
    const args = luajit.Args{ .state = &state, .base = 1 };
    state.pushInteger(args.checkInteger(1) - args.checkInteger(2));
    return 1;
}

/// Lua C callback that doubles argument 1 through `Args`.
fn doubleArgument(l: ?*luajit.c.lua_State) callconv(.c) c_int {
    // This wrapper borrows the state Lua passed to the callback.
    var state = luajit.State{ .raw = l };
    // Argument numbering starts at the callback frame's base, index 1.
    const args = luajit.Args{ .state = &state, .base = 1 };
    state.pushInteger(args.checkInteger(1) * 2);
    return 1;
}

test "every block a state takes comes back to the caller's allocator" {
    var counter = Counter{ .allocator = testing.allocator };
    defer counter.deinit();

    var state = try luajit.State.initWithAllocator(&countingAlloc, &counter);
    defer if (state.raw != null) state.deinit();

    state.openLibs();
    try state.run(
        \\local t = {}
        \\for i = 1, 200 do t[i] = ("x"):rep(i) end
        \\return #t
    , "=alloc");
    try testing.expectEqual(@as(luajit.Integer, 200), state.toInteger(1));

    try testing.expect(counter.blocks.count() > 0);

    state.deinit();
    try testing.expectEqual(@as(usize, 0), counter.blocks.count());
    try testing.expectEqual(counter.allocated, counter.freed);
}

test "an allocator swapped in and out owns nothing, and the one restored owns the rest" {
    var first = Counter{ .allocator = testing.allocator };
    defer first.deinit();
    var second = Counter{ .allocator = testing.allocator };
    defer second.deinit();

    var state = try luajit.State.initWithAllocator(&countingAlloc, &first);
    defer if (state.raw != null) state.deinit();
    state.openLibs();
    try state.run(
        \\local t = {}
        \\for i = 1, 64 do t[i] = ("x"):rep(i) end
        \\return #t
    , "=swap");

    // Allocator changes do not migrate blocks; restore the prior pair before closing.
    try testing.expect(first.blocks.count() > 0);
    const previous = state.setAllocator(&countingAlloc, &second);
    _ = state.setAllocator(previous.function, previous.user_data);

    try testing.expectEqual(@as(usize, 0), second.blocks.count());
    try testing.expectEqual(@as(usize, 0), second.allocated);

    state.setTop(0);
    try state.run(
        \\local t = {}
        \\collectgarbage("collect")
        \\for i = 1, 64 do t[i] = ("y"):rep(i) end
        \\return #t
    , "=swap");
    try testing.expectEqual(@as(luajit.Integer, 64), state.toInteger(1));

    state.deinit();
    try testing.expectEqual(@as(usize, 0), first.blocks.count());
    try testing.expectEqual(first.allocated, first.freed);
}

/// The bookkeeping side of the allocator tests: one entry per live block.
const Counter = struct {
    allocator: std.mem.Allocator,
    blocks: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    allocated: usize = 0,
    freed: usize = 0,

    fn deinit(self: *Counter) void {
        self.blocks.deinit(self.allocator);
    }
};

/// LuaJIT objects require 8-byte alignment (`src/lj_obj.h:174`).
const Block = []align(8) u8;
const block_alignment: std.mem.Alignment = .@"8";

/// LuaJIT allocator callback; record block sizes for Zig `free`/`realloc`, not `osize`.
fn countingAlloc(
    user_data: ?*anyopaque,
    pointer: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque {
    _ = osize;
    const self: *Counter = @ptrCast(@alignCast(user_data.?));

    if (nsize == 0) {
        if (pointer) |address| {
            const entry = self.blocks.fetchRemove(@intFromPtr(address)) orelse
                return null;
            self.allocator.free(blockAt(address, entry.value));
            self.freed += entry.value;
        }
        return null;
    }

    if (pointer) |address| {
        // Remove the old address before resize, which may move the block.
        const entry = self.blocks.fetchRemove(@intFromPtr(address)) orelse
            return null;
        const grown = self.allocator.realloc(blockAt(address, entry.value), nsize) catch {
            // On failure, restore the original allocation record.
            self.blocks.putAssumeCapacity(@intFromPtr(address), entry.value);
            return null;
        };
        self.blocks.putAssumeCapacity(@intFromPtr(grown.ptr), nsize);
        self.freed += entry.value;
        self.allocated += nsize;
        return @ptrCast(grown.ptr);
    }

    const fresh = self.allocator.alignedAlloc(u8, block_alignment, nsize) catch
        return null;
    self.blocks.put(self.allocator, @intFromPtr(fresh.ptr), nsize) catch {
        self.allocator.free(fresh);
        return null;
    };
    self.allocated += nsize;
    return @ptrCast(fresh.ptr);
}

/// Recover the aligned allocation slice and its recorded length.
fn blockAt(address: *anyopaque, length: usize) Block {
    return @as([*]align(8) u8, @ptrCast(@alignCast(address)))[0..length];
}

test "a coroutine yields a value and resumes with another" {
    var state = openState();
    defer state.deinit();

    try state.run(
        \\local co = coroutine.create(function(a)
        \\  local b = coroutine.yield(a + 1)
        \\  return b * 2
        \\end)
        \\local _, first = coroutine.resume(co, 10)
        \\local _, second = coroutine.resume(co, 4)
        \\return first, second, coroutine.status(co)
    , "=coroutine");
    try testing.expectEqual(@as(luajit.Integer, 11), state.toInteger(1));
    try testing.expectEqual(@as(luajit.Integer, 8), state.toInteger(2));
    try testing.expect(state.toString(3).eql("dead"));
}

test "a coroutine created from Zig runs to completion" {
    var state = openState();
    defer state.deinit();

    const thread = state.newThread();
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TTHREAD), state.typeOf(-1));

    // `lua_resume` uses the coroutine's own stack for its function and arguments (`src/lj_api.c:1100-1110`).
    luajit.c.lua_pushcclosure(thread.raw, &doubleArgument, 0);
    luajit.c.lua_pushinteger(thread.raw, 21);

    try thread.@"resume"(1);
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_OK), thread.status());
    try testing.expectEqual(@as(luajit.Integer, 42), luajit.c.lua_tointeger(thread.raw, -1));

    state.setTop(0);
}

test "a full collection clears a weak table that still looks full" {
    var state = openState();
    defer state.deinit();

    try state.run(
        \\local t = setmetatable({}, { __mode = "v" })
        \\t[1] = {}
        \\local before = next(t) ~= nil
        \\collectgarbage("collect")
        \\return before, next(t) == nil
    , "=weak");
    try testing.expect(state.toBoolean(1));
    try testing.expect(state.toBoolean(2));
}

test "the compiler engine can be switched off, flushed and back on" {
    var state = openState();
    defer state.deinit();

    // `jit.status` returns the engine flag first (`src/lib_jit.c:101-109`); clear the stack before each query.
    try testing.expect(luajit.jit.setEngine(&state, luajit.jit.on));
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=jit");
    try testing.expect(state.toBoolean(1));

    try testing.expect(luajit.jit.disable(&state));
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=jit");
    try testing.expect(!state.toBoolean(1));

    // Flushing drops traces without changing whether the engine is on (`src/lj_dispatch.c:264-272`).
    try testing.expect(luajit.jit.flushEngine(&state));
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=jit");
    try testing.expect(!state.toBoolean(1));

    try testing.expect(luajit.jit.enable(&state));
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=jit");
    try testing.expect(state.toBoolean(1));

    try testing.expect(luajit.jit.flushEngine(&state));
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=jit");
    try testing.expect(state.toBoolean(1));

    // Disabling JIT leaves the interpreter available.
    try testing.expect(luajit.jit.disable(&state));
    state.setTop(0);
    try state.run(
        \\local s = 0
        \\for i = 1, 1000 do s = s + i end
        \\return s
    , "=jit");
    try testing.expectEqual(@as(luajit.Integer, 500500), state.toInteger(1));
    try testing.expect(luajit.jit.enable(&state));
}

test "the compiler modes say which target they could act on" {
    var state = openState();
    defer state.deinit();

    // The boolean mirrors `luaJIT_setmode`: false means the target is unavailable (`src/lj_dispatch.c:285,326`).
    try state.load("local x = 1 return x", "=target");
    try testing.expect(luajit.jit.setMode(&state, -1, luajit.jit.func | luajit.jit.off));
    try testing.expect(luajit.jit.setMode(&state, -1, luajit.jit.func | luajit.jit.flush));
    state.setTop(0);

    state.pushCFunction(&doubleArgument);
    try testing.expect(!luajit.jit.setMode(&state, -1, luajit.jit.func | luajit.jit.off));
    state.setTop(0);

    try testing.expect(!luajit.jit.setMode(&state, 0, luajit.c.LUAJIT_MODE_WRAPCFUNC | luajit.jit.on));
}

test "bit operations agree with Zig's own integer operators" {
    var state = openState();
    defer state.deinit();

    const Op = enum { band, bor, bxor };
    const Case = struct { op: Op, left: i32, right: i32, source: []const u8 };
    const cases = [_]Case{
        .{ .op = .band, .left = 0xff00, .right = 0x0ff0, .source = "bit.band(0xff00, 0x0ff0)" },
        .{ .op = .band, .left = -1, .right = 0x7f, .source = "bit.band(-1, 0x7f)" },
        .{ .op = .bor, .left = 123456, .right = 654321, .source = "bit.bor(123456, 654321)" },
        .{ .op = .bxor, .left = -32768, .right = 32767, .source = "bit.bxor(-32768, 32767)" },
        .{ .op = .band, .left = -1, .right = 0, .source = "bit.band(-1, 0)" },
    };
    var source_buffer: [64]u8 = undefined;
    for (cases) |case| {
        state.setTop(0);
        try state.run(try std.fmt.bufPrint(&source_buffer, "return {s}", .{case.source}), "=bit");
        const expected: i32 = switch (case.op) {
            .band => case.left & case.right,
            .bor => case.left | case.right,
            .bxor => case.left ^ case.right,
        };
        try testing.expectEqual(
            @as(luajit.Number, @floatFromInt(expected)),
            state.toNumber(1),
        );
    }

    state.setTop(0);
    try state.run(
        "return bit.arshift(-8, 1), bit.bnot(0), bit.lshift(1, 4), bit.bor(123456, 654321)"
    , "=bit");
    try testing.expectEqual(@as(luajit.Number, -4), state.toNumber(1));
    try testing.expectEqual(@as(luajit.Number, -1), state.toNumber(2));
    try testing.expectEqual(@as(luajit.Number, 16), state.toNumber(3));
    try testing.expectEqual(
        @as(luajit.Number, @floatFromInt(@as(i32, 123456) | @as(i32, 654321))),
        state.toNumber(4),
    );
}

test "the FFI reports this target's widths and calls into libc" {
    var state = bareState();
    defer state.deinit();

    state.openLibs();
    // `openLibs` preloads FFI; `openFfi` installs the global.
    state.openFfi();

    // LuaJIT requires an FFI declaration before a C symbol can be indexed (`src/lj_clib.c:348-350`).
    try state.run("ffi.cdef[[ int abs(int); ]]", "=ffi");
    state.setTop(0);

    // Convert cdata to Lua numbers before reading them through the C API (`src/lj_api.c:363-377`).
    try runReporting(&state,
        \\return tonumber(ffi.sizeof("int")) * 256
        \\     + tonumber(ffi.sizeof("void*")) * 65536,
        \\       tonumber(ffi.sizeof("double")) * 1024,
        \\       ffi.abi("64bit") == (tonumber(ffi.sizeof("void*")) == 8),
        \\       tonumber(ffi.C.abs(-42))
    , "=ffi", null);
    const expected = @as(luajit.Number, @floatFromInt(4 * 256)) +
        @as(luajit.Number, @floatFromInt(@sizeOf(usize) * 65536));
    try testing.expectEqual(expected, state.toNumber(1));
    try testing.expectEqual(
        @as(luajit.Number, @floatFromInt(@sizeOf(f64) * 1024)),
        state.toNumber(2),
    );
    try testing.expectEqual(@sizeOf(usize) == 8, state.toBoolean(3));
    try testing.expectEqual(@as(luajit.Number, 42), state.toNumber(4));
}

test "an FFI call with the wrong argument type is an error, not a wrong answer" {
    var state = bareState();
    defer state.deinit();

    state.openLibs();
    state.openFfi();

    // Declare the C symbol before indexing it through the FFI (`src/lj_clib.c:348-350`).
    try state.run("ffi.cdef[[ int abs(int); ]]", "=ffi");
    state.setTop(0);

    // A string cannot match `abs`'s declared `int`; the protected call returns an error.
    try testing.expectError(
        error.RuntimeError,
        runReporting(&state, "return ffi.C.abs(\"not a number\")", "=ffi", error.RuntimeError),
    );

    // The state remains usable after a protected error.
    state.setTop(0);
    try state.run("return tonumber(ffi.C.abs(-42))", "=ffi");
    try testing.expectEqual(@as(luajit.Number, 42), state.toNumber(1));
}

test "openStringBuffer installs the dotted global that needs two tables" {
    var state = bareState();
    defer state.deinit();

    state.openLibs();
    state.openStringBuffer();

    // The module needs an explicit `string.buffer` field; its constructor is `string.buffer.new`.
    // `put`, `tostring`, and `#` preserve all five bytes, including the embedded NUL.
    try runReporting(&state,
        \\local b = string.buffer.new(16)
        \\b:put("ab")
        \\b:put("\x00cd")
        \\return tostring(b), #b
    , "=buffer", null);
    try testing.expectEqualSlices(u8, "ab\x00cd", state.toString(1).slice());
    try testing.expectEqual(@as(luajit.Integer, 5), state.toInteger(2));
}
