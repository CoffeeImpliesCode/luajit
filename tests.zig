// SPDX-License-Identifier: MIT
//
//! Behavioural tests for the LuaJIT facade.
//!
//! Every expected value in this file is either an independent known answer --
//! a number IEEE 754 says a conversion must produce, a string `src/luaconf.h`
//! says the library must format, a value Zig's own integer operators produce
//! -- or a boundary that the native sources fix: what a weak table does when a
//! collection runs, how a chunk name prefixes an error message, how many
//! results a protected call keeps, what each standard library computes, and
//! what `jit.status` says after the engine is switched off. Nothing here
//! records what the library happened to print, pins a release string, checks
//! that a declaration exists, or counts how many times the allocator ran.
//!
//! ## Where the answers come from
//!
//!  * `tostring(1/3)` is `"0.33333333333333"`, which is what `LUA_NUMBER_FMT` at
//!    `src/luaconf.h:122` (`%.14g`) says a double formats to. The answer is in
//!    the header, not in this file's memory of it.
//!  * There is no integer subtype in this build. `LUAJIT_NUMMODE` is not
//!    defined, so `LJ_DUALNUM` is 0 (`src/lj_arch.h:575-586`) and `setintV`
//!    stores `o->n = (lua_Number)i` rather than a tagged int
//!    (`src/lj_obj.h:953-960`). `lua_Integer` is `ptrdiff_t`
//!    (`src/luaconf.h:106`) and is only the type the C API converts to and
//!    from, so 2^53 + 1 is 2^53 by the time anything can read it.
//!  * The bit-operation answers are computed here with Zig's own `&`, `|`, `^`
//!    and `>>` on `i32`, so they are a second implementation agreeing with
//!    LuaJIT's rather than a transcript of it.
//!  * The FFI answers are computed here with Zig's `@sizeOf`, so they follow
//!    the target this test binary was compiled for.
//!  * The library answers are the values each standard library computes from
//!    what it is given -- an exact sum, a join, a formatted field, a floor, a
//!    year -- not the presence of a global name, so a library that registered
//!    nothing usable fails here rather than agreeing with a table written
//!    beside it.
//!  * The compiler answers are `jit.status`'s own, and the compiler calls
//!    answer 1 for success (`src/lj_dispatch.c:326`), which is the polarity
//!    the facade's booleans have to keep.
//!  * The one error-message answer is the chunkname prefix that a raise in a
//!    Lua frame carries (`src/lj_debug.c:360-377`, so a chunk loaded as
//!    `=probe` reports `probe:1: ...`). The wording a raise inside a C frame is
//!    wrapped in -- the argument error at `src/lj_errmsg.h:41-42` and the FFI
//!    conversion error at `src/lj_errmsg.h:165` -- is upstream's own text and is
//!    deliberately not pinned: those tests assert the status the raise came
//!    back as, not the sentence it arrived in.
//!
//! ## The stack between calls
//!
//! A protected call leaves what the function returned above whatever was
//! already on the stack; nothing in this module resets the stack for you. Tests
//! that read absolute indices say `setTop(0)` first, because a check that
//! reads a stale value is a check that passes for the wrong reason.
//!
//! ## What a failing chunk leaves behind
//!
//! `RunError` names the kind of failure and nothing else, so a test that read
//! only that would report `RuntimeError` and leave the reader to work out
//! which of the raises in the chunk it was. The chunks below therefore run
//! through `runReporting`, which is `State.run` with one addition: when the
//! call does not end the way the test expects, it prints the message the
//! library left on the stack -- read through `errorMessage`, so it is the
//! library's own account -- before returning the status to assert on.
//!
//! ## What a runtime-loading build needs
//!
//! Such a build has no library until `load` has been called, so every test
//! calls `nativeReady()` first. That is a no-op at comptime in a linked build.

const std = @import("std");
const luajit = @import("luajit");
const testing = std.testing;

/// A shared object exporting the entry points of `src/lua.h`, `src/lauxlib.h`,
/// `src/lualib.h` and the generated `src/luajit.h`, named by the environment in
/// a runtime-loading build.
const provider_variable = "LUAJIT_TEST_PROVIDER";

/// Make the native library usable, once, before a test calls the facade.
///
/// In a linked build the facade is usable already and this is a no-op at
/// comptime. In a runtime-loading build every call into the module goes through
/// a table that `load` fills, so this is where the one explicit load happens.
/// It is safe to call from every test: the contract makes the same request
/// idempotent, and the loader keeps the handle to the end of the process.
///
/// A build that was not told which file to load stops here with the variable's
/// name, rather than reporting a test failure that says nothing about the
/// reason.
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

/// A state with the standard libraries open, which is what nearly every test
/// below wants.
fn openState() luajit.State {
    nativeReady();
    var state = luajit.State.init() catch @panic("tests.zig: no Lua state; the " ++
        "allocator could not provide one");
    state.openLibs();
    return state;
}

/// A state with nothing open, for the tests that open libraries themselves.
fn bareState() luajit.State {
    nativeReady();
    return luajit.State.init() catch @panic("tests.zig: no Lua state; the " ++
        "allocator could not provide one");
}

/// Run `source` as a chunk and answer the status the call produced, printing
/// what the library said when that status is not the expected one.
///
/// `State.run` reports a failure as an error value and leaves the text that
/// says why on the stack, so a caller that reads only the error value cannot
/// say what raised. `expected` is null when the chunk is supposed to succeed.
/// The status is returned either way, so `try` propagates it and `expectError`
/// matches it exactly as they do through `State.run`.
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

/// Print the message left on the stack by a failure the caller did not expect.
///
/// This is the library's own account rather than a restatement of the status:
/// `errorMessage` reads the value `luaL_loadbuffer` or `lua_pcall` left on the
/// stack, and that value is the text which explains the status.
fn reportUnexpected(
    state: *const luajit.State,
    got: luajit.RunError,
    expected: ?luajit.RunError,
) void {
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
    // `=probe` makes the chunk name the first part of the message, which is
    // what makes an error attributable; the wording after the prefix is
    // upstream's.
    const message = state.errorMessage();
    try testing.expect(std.mem.startsWith(u8, message.slice(), "probe:1:"));
    try testing.expect(std.mem.indexOf(u8, message.slice(), "boom") != null);

    // The same state runs the next chunk. A protected call is what makes the
    // failure recoverable at all.
    state.setTop(0);
    try state.run("return 'still here'", "=after");
    try testing.expect(state.toString(1).eql("still here"));
}

test "a protected call returns the results it was asked for and disposes the rest" {
    var state = openState();
    defer state.deinit();

    // Every case below empties the stack first. A protected call pushes what
    // the function returned above whatever was already on the stack, so an
    // absolute index means what it says only when the caller knows what is
    // underneath it.
    try state.load("return 'first', 'second', 'third'", "=count");
    try state.protectedCall(0, 1);
    try testing.expectEqual(@as(usize, 1), state.top());
    try testing.expect(state.toString(1).eql("first"));

    // Asking for none leaves nothing to pop: the count is a count, not a hint.
    state.setTop(0);
    try state.load("return 1, 2, 3", "=count");
    try state.protectedCall(0, 0);
    try testing.expectEqual(@as(usize, 0), state.top());

    // Asking for more than the function returned pads with nil, which is the
    // other half of the same rule.
    state.setTop(0);
    try state.load("return 'only'", "=count");
    try state.protectedCall(0, 3);
    try testing.expectEqual(@as(usize, 3), state.top());
    try testing.expect(state.toString(1).eql("only"));
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(2));
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(3));

    // `multret` is the one count that is not a number: everything the function
    // returned is kept, which is what `run` passes.
    state.setTop(0);
    try state.load("return 10, 20, 30", "=count");
    try state.protectedCall(0, luajit.multret);
    try testing.expectEqual(@as(usize, 3), state.top());
    try testing.expectEqual(@as(luajit.Integer, 30), state.toInteger(3));

    // The arguments go in above the function and both are gone afterwards, so
    // what is left is the results alone.
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

    // A value that was on the stack before the call is still there afterwards:
    // the failure unwound to the protected call, not to this function, and the
    // error object is the one value the call added.
    state.pushString("below");
    try state.load("error('raised')", "=fail");
    try testing.expectError(
        error.RuntimeError,
        state.protectedCall(0, luajit.multret),
    );
    try testing.expectEqual(@as(usize, 2), state.top());
    try testing.expect(state.toString(1).eql("below"));

    // `errorMessage` reads the top of the stack with `lua_tolstring`, and the
    // value it converts there is the error the call left. Reading it twice
    // gives the same bytes: the read does not consume it.
    const message = state.errorMessage();
    try testing.expect(std.mem.startsWith(u8, message.slice(), "fail:1:"));
    try testing.expect(state.errorMessage().eql(message.slice()));

    // Clearing it and running again is the recovery a caller has, in the same
    // state: nothing had to be reopened.
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

    // `lua_Number` is `double` (`src/luaconf.h:119`), and `lua_tointegerx`
    // scans a string into a number rather than into an integer. With the VM
    // in single-number mode -- which is what this package builds, since
    // `LUAJIT_NUMMODE` is not defined and `LJ_DUALNUM` follows from the
    // architecture's default (`src/lj_arch.h:575-586`) -- `lj_strscan_number`
    // *is* `lj_strscan_num` (`src/lj_strscan.h:28-32`), and that only ever
    // produces a number (`src/lj_strscan.c:535-540`, and its decimal fast path
    // at `:500-513`, which stores a double even for "42").
    state.pushString("42");
    try testing.expectEqual(@as(?luajit.Integer, 42), state.toIntegerX(1));
    try testing.expectEqual(@as(?luajit.Number, 42), state.toNumberX(1));

    // A fraction is not refused either: the double is cast to the integer
    // type (`src/lj_api.c:444`), so this answers 3 and not null. Pinning that
    // is the point: a caller who believes otherwise writes a null check that
    // can never fire.
    state.setTop(0);
    state.pushString("3.5");
    try testing.expectEqual(@as(?luajit.Integer, 3), state.toIntegerX(1));
    try testing.expectEqual(@as(?luajit.Number, 3.5), state.toNumberX(1));

    // What it does refuse is a string that does not scan as a number at all.
    // The scanner consumes the whole string or nothing, so trailing text is
    // not a number with something after it (`src/lj_strscan.c:496`).
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
    // Every Lua number in this build is a `double`, with no integer subtype
    // beside it: `LUAJIT_NUMMODE` is not defined, so `LJ_DUALNUM` is 0
    // (`src/lj_arch.h:575-586`) and `setintV` stores `o->n = (lua_Number)i`
    // instead of a tagged int (`src/lj_obj.h:953-960`). On a 64-bit target
    // `setintptrV` is `setint64V` (`src/lj_obj.h:970-974`), which only keeps an
    // int32 when `LJ_DUALNUM` and otherwise stores the double, and
    // `lua_pushinteger` is that path (`src/lj_api.c:632-635`). The value is a
    // double from the moment it is pushed.
    const exact = std.math.cast(luajit.Integer, @as(i64, 1) << 53) orelse
        return error.SkipZigTest;
    const past = exact + 1;

    // Both halves of the boundary, computed the way IEEE 754 defines them and
    // not by memory of what the library printed: 2^53 is the last integer a
    // double counts exactly, and converting the next one rounds to it.
    const as_number: luajit.Number = @floatFromInt(exact);
    try testing.expectEqual(@as(luajit.Number, 9007199254740992.0), as_number);
    try testing.expectEqual(as_number, @as(luajit.Number, @floatFromInt(past)));

    var state = bareState();
    defer state.deinit();

    // The representable one comes back as itself, through both reads: the
    // branch `lua_tointegerx` takes for a slot that already holds an int
    // (`src/lj_api.c:427-429`) is not the branch this build can reach, and the
    // value reaches `lj_num2int_type` through `lua_Number` instead, which is a
    // plain cast (`src/lj_obj.h:1010`).
    state.pushInteger(exact);
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNUMBER), state.typeOf(1));
    try testing.expectEqual(@as(?luajit.Integer, exact), state.toIntegerX(1));
    try testing.expectEqual(exact, state.toInteger(1));

    // The unrepresentable one is not refused, and does not answer zero
    // either: the slot holds the double 2^53, so both reads answer 2^53. That
    // is the fact this test exists for -- a caller that pushes 2^53 + 1 and
    // compares the read against what it pushed is comparing against a value no
    // slot in this build can hold, and `lua_pushinteger` hands it back in
    // silence.
    state.setTop(0);
    state.pushInteger(past);
    try testing.expectEqual(@as(?luajit.Integer, exact), state.toIntegerX(1));
    try testing.expectEqual(exact, state.toInteger(1));

    // The same digits as a string take the same round trip through the
    // scanner, so what the previous case lost is the representation and
    // nothing about reading a string: `lj_strscan_number` produces a number
    // (`src/lj_strscan.h:27-31`, `src/lj_strscan.c:535-541`).
    state.setTop(0);
    state.pushString("9007199254740993");
    try testing.expectEqual(@as(?luajit.Integer, exact), state.toIntegerX(1));
    try testing.expectEqual(@as(?luajit.Number, as_number), state.toNumberX(1));

    // And the digits that are exact are read back exactly, which is the other
    // half of the boundary: 2^53 survives, and it is one below the value that
    // did not.
    state.setTop(0);
    state.pushString("9007199254740992");
    try testing.expectEqual(@as(?luajit.Integer, exact), state.toIntegerX(1));
    try testing.expectEqual(@as(?luajit.Number, as_number), state.toNumberX(1));
}

test "a double is formatted the way the configuration header says" {
    var state = openState();
    defer state.deinit();

    // `LUA_NUMBER_FMT` is `%.14g` (`src/luaconf.h:122`), so a third is
    // fourteen significant digits and no more.
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
    // `lua_tolstring` converts in place, so the slot is a string afterwards.
    // This is the one read in the facade with a side effect, and a caller
    // walking a stack of unknown values needs to know it is there.
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

    // `luaL_openlibs` is the ordinary way; `Library.open` is for a caller who
    // wants one library and nothing else. `base` installs `_G` first, which is
    // what the other libraries register themselves into.
    try testing.expectEqual(@as(usize, 0), state.top());
    luajit.Library.base.open(&state);
    luajit.Library.math.open(&state);

    // Both opens left the stack as they found it (`luaopen_*` returns what it
    // installed and this drops it), so index 1 below is the chunk's own result
    // rather than a leftover.
    try testing.expectEqual(@as(usize, 0), state.top());
    try state.run("return math.floor(3.7), math.pi > 3", "=one");
    try testing.expectEqual(@as(luajit.Number, 3), state.toNumber(1));
    try testing.expect(state.toBoolean(2));

    // Nothing else was opened, and that is observable: `io` and `os` are two
    // libraries a caller may not want to hand a script.
    state.setTop(0);
    try state.run("return io, os, coroutine", "=one");
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(1));
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(2));

    // `coroutine` is the exception the one-library story has to mention: it is
    // part of `luaopen_base` (`src/lib_base.c:706`), so a state with only the
    // base library already has it. It is read as a type rather than as text,
    // because `lua_tolstring` converts a number and answers null for anything
    // else (`src/lj_api.c:493-506`): reading a table as a string here would
    // answer an empty borrow, and never the word "table".
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TTABLE), state.typeOf(3));
}

test "every library opens and answers a known result" {
    nativeReady();

    // Each library is opened the way `luaL_openlibs` opens its own
    // (`src/lib_init.c:42-46`): the `luaopen_*` goes in as an argument to a Lua
    // C function and is called from inside it, so Lua is the caller and there
    // is a call in progress. Calling one straight from Zig is not the same
    // thing, and `package` is where that shows: `luaopen_package` copies the
    // package table into `LUA_ENVIRONINDEX` (`src/lib_package.c:601`), and
    // `copy_slot` accepts that index only for a calling Lua function
    // (`src/lj_api.c:187-190`); with no call in progress it raises
    // `LJ_ERR_NOENV`, and unprotected that is the library's panic handler
    // rather than a returned error (`src/lib_aux.c:313-319`). The frame is not
    // decoration either: it is what makes the loaders the package table's
    // environment (`src/lj_api.c:89-93`), which is how `require` reaches
    // `package.preload`.
    //
    // What each library is asked for is a *result*, not the existence of a name.
    // Every expected string below is worked out here, independently of this
    // build: a wrapped coroutine that returns 6*7 is 42, and so is a preloaded
    // module that returns it; three elements joined with "+" are `a+b+c`;
    // `io.type` answers "file" for a real handle; the zeroth UTC second is the
    // year 1970 (`os.date` with the `!` prefix is UTC and takes the time as its
    // second argument); `string.format("%05d", 42)` is `00042`;
    // `math.floor(-1.5)` is -2; `debug.getinfo(1).what` asked from inside a
    // function body is "Lua" (the row below derives why); and `0xff00 & 0x0ff0`
    // is `0x0f00`, which is 3840. A library that opened but installed nothing
    // usable could not produce any of them.
    //
    // `jit.arch` is the one row not computed from a value the library is
    // handed, and it is the one thing a library cannot answer differently: it
    // is `LJ_ARCH_NAME` (`src/lib_jit.c:758`), which `src/lj_arch.h` spells
    // from the architecture this VM was generated for. LuaJIT's names are not
    // Zig's -- `x64` and `arm64` where Zig says `x86_64` and `aarch64` -- so
    // the expected string is derived from this test binary's own target, the
    // same shape as the FFI widths above, rather than read out of a run.
    const expected_jit_arch = jitArchName() orelse return error.SkipZigTest;

    const openers = [_]struct {
        name: []const u8,
        opener: luajit.c.lua_CFunction,
        probe: []const u8,
        expected: []const u8,
        // A probe that hands back a *function* rather than the answer itself
        // is called once more before the answer is read: that row needs the
        // frame inside the function, which the chunk's own frame cannot be.
        call_result: bool = false,
    }{
        // `base` installs `_G` and `coroutine` in one call (`src/lib_base.c:702-708`),
        // so a wrapped coroutine is available without any other library.
        .{
            .name = "base",
            .opener = luajit.c.luaopen_base,
            .probe = "return tostring(coroutine.wrap(function() return 6 * 7 end)())",
            .expected = "42",
        },
        // The preload searcher is one of what `package` installs, so this
        // answers through that library and not through anything else: the
        // module is registered here and `require` returns what the function
        // returns, 6*7.
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
            // `!` is UTC and the second argument is the time, so the zeroth
            // second of the epoch is in the year 1970 whatever the local zone.
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
        // The frame a probe can see from the chunk is the chunk, and a chunk is
        // not a function: `lj_debug_getinfo` answers "main" for a prototype with
        // no first line and no line count (`src/lj_debug.c:468`), which is what a
        // main chunk loaded from a string is, so "main" is all this call shape
        // could answer. Level 1 asked from inside a function body is that
        // function instead. `lj_debug_frame` starts its walk at `L->base-1`
        // (`src/lj_debug.c:25-47`), the slot of the function executing -- inside
        // `debug.getinfo`, its own C closure -- so level 1 is the Lua frame that
        // called it, the same reading `ll_module` needs to tell "not called from
        // a Lua function" apart from a call (`src/lib_package.c:482-485`). That
        // frame's prototype has a first line and answers "Lua", so the probe
        // returns the function and the API calls it: the row asks the question
        // it means, not a renamed observation of the chunk's own frame.
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
        // The architecture string, and nothing that reads the engine state:
        // `the compiler engine can be switched off, flushed and back on` in
        // this file already owns the on/off transition through `jit.setEngine`,
        // and a second copy of it here would be that check written twice. What
        // this row adds is that the `jit` table is this build's: `jit.arch` is
        // `LJ_ARCH_NAME` (`src/lib_jit.c:758`), which `src/lj_arch.h` spells
        // from the architecture the VM was generated for, and the expected
        // string is derived from this binary's own target rather than from a
        // run.
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
        // `base` registers the table every other library below registers into,
        // so it is opened first except in its own row, where the opener runs.
        if (entry.opener != luajit.c.luaopen_base) luajit.Library.base.open(&state);
        state.pushCFunction(&openLibraryThroughCall);
        state.setGlobal("open_library");
        state.pushCFunction(entry.opener);
        // `luaL_openlibs` passes the module name (`src/lib_init.c:44`) and no
        // `luaopen_*` reads it: each takes its own from the `LJ_LIB_REG` in its
        // source (`src/lj_lib.h:91-92`, `src/lib_base.c:705-706`).
        state.pushString("");
        try state.load("return open_library()", "=open");
        // Two arguments, zero results, exactly as `lua_call(L, 1, 0)` does at
        // `src/lib_init.c:45`: the opener and the module name go in, and
        // whatever the opener returns is dropped. That leaves an empty stack,
        // which is what index 1 below then means.
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
            // A probe that raised is reported by name too: a bare
            // `error.RuntimeError` from a loop over many rows says nothing
            // about which library was involved.
            std.debug.print(
                "\ntests.zig: {s}: the probe raised ({t})\n  probe: {s}\n  message: {s}\n",
                .{ entry.name, err, entry.probe, state.errorMessage().slice() },
            );
            return error.ProbeRaised;
        };

        // A row that asked for a function gets it called through the API
        // before the answer is read. `lua_pcall` calls whatever is on the top
        // of the stack -- `api_call_base` with zero arguments is `L->top`
        // itself (`src/lj_api.c:1100-1109`), where the chunk left the function
        // it returned -- so this is the route the chunk itself went through,
        // not a second way in. A value that cannot be called raises here and is
        // named like any other probe raise rather than read as an answer.
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

        // The library the answer came from, the probe that asked, the answer as
        // derived here, the answer as it arrived and the Lua type it arrived as
        // are printed together when they disagree, so a failure names its row
        // instead of pointing at one line shared by every row of the table. The
        // type is read *before* `toString` and reported because `toString` is
        // `lua_tolstring` and converts the slot in place
        // (`src/lj_api.c:493-506`): a value that is neither a string nor a
        // number answers an empty borrow, which is indistinguishable from an
        // empty string unless the type is reported beside it -- and asking
        // afterwards would answer "string" for every row and say nothing.
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

/// The `jit.arch` string this build's LuaJIT reports, worked out from Zig's
/// own target.
///
/// `src/lj_arch.h` spells its own architecture names and they are not Zig's:
/// `x86_64` is `x64` and `aarch64` is `arm64`. Deriving the expected string
/// here from `@import("builtin").target` makes it an answer about the target
/// this binary was compiled for, which the library has to agree with, rather
/// than a constant either side could agree about by accident.
///
/// Null for an architecture LuaJIT 2.1 does not support at all: the chain at
/// `src/lj_arch.h:54-70` names x86, x64, ARM, arm64, PPC, MIPS and MIPS64, and
/// `check` runs that target's own preprocessor over the header and requires
/// upstream's refusal, so there is no build here whose answer could differ.
fn jitArchName() ?[]const u8 {
    // Zig has a separate tag per byte order and LuaJIT names the byte order
    // inside `LJ_ARCH_NAME` (`src/lj_arch.h:326-328`, `:403-433`), so the
    // mapping has to be per-tag rather than per-family.
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

/// Call the `luaopen_*` argument 1 names, with argument 2 as its `libname`.
///
/// This is `luaL_openlibs`' own shape, one library at a time
/// (`src/lib_init.c:43-45`): the opener arrives as an argument, so Lua is
/// inside a call while it runs, which is what `luaopen_package` needs in order
/// to set its caller's environment (`src/lib_package.c:601`).
///
/// It answers zero values, so the two arguments it was given are gone with it
/// and the caller is left with an empty stack.
fn openLibraryThroughCall(l: ?*luajit.c.lua_State) callconv(.c) c_int {
    var state = luajit.State{ .raw = l };
    const opener = luajit.c.lua_tocfunction(l.?, 1) orelse return 0;
    // Copied out before the push: argument 2 lives on this frame's stack, and
    // pushing anything can collect and move it.
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

    // `luaopen_ffi` registers its members with a null name on purpose ("Note:
    // no global \"ffi\" created!", `src/lib_ffi.c:856`) and so does
    // `luaopen_string_buffer` (`src/lib_buffer.c:351-357`), which returns its
    // module table for the caller to name or to discard. What the running
    // library installs is what the checks below read, not what this facade's
    // own name list says about it.

    state.openLibs();
    try state.run(
        \\return rawget(_G, "ffi"), rawget(string, "buffer")
    , "=global");
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(1));
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TNIL), state.typeOf(2));

    // What `luaL_openlibs` does instead is put `ffi` in the registry's
    // `_PRELOAD` (`src/lib_init.c:32-52`), which is where `require` finds it:
    // loaded on first use, and not a global before then.
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

    // The same bytes through `lua_pushstring` stop at the NUL, which is what
    // the facade's length-carrying push exists to avoid. `lua_pushstring` is
    // reached through `c` rather than wrapped, because a wrapper for it would
    // have to take a NUL-terminated string and would lose exactly these bytes.
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

    // `luaL_ref` pops the value and parks it in the registry under an integer
    // key, so what the next collection sees is the reference rather than the
    // stack: the table is unreachable from here, and only the registry holds it.
    // The registry's index is a pseudo-index (`src/lua.h:39`), not a slot, so it
    // is read from the translation rather than computed from the stack.
    state.newTable();
    const reference = state.ref(luajit.c.LUA_REGISTRYINDEX);
    try testing.expect(reference > 0); // neither LUA_REFNIL nor LUA_NOREF
    try testing.expectEqual(@as(usize, 0), state.top()); // ref popped the value

    state.collect();
    luajit.c.lua_rawgeti(state.raw, luajit.c.LUA_REGISTRYINDEX, reference);
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_TTABLE), state.typeOf(-1));
    state.setTop(0);

    // `unref` is the other half of the same transition: it takes the value out
    // of the registry (`src/lib_aux.c:299`, which links the slot onto the free
    // list), so nothing is anchoring the table any more and the slot that used
    // to name it no longer does.
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

    // Walking it is the documented `next` protocol: a key in, two values out,
    // and the key consumed by the call that ends the walk.
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

    // The same function given the wrong type raises through
    // `luaL_checkinteger` (`src/lj_api.c:447-459`): a string that does not
    // scan as a number is the one case it refuses, and the protected call
    // turns the raise into a returned error. That it is an *error* rather than
    // a wrong answer is the claim here. The sentence the library formats around
    // `lj_err_argt` (`src/lj_err.c:1105-1117`) is upstream's own wording and is
    // not asserted, so a change there is not this facade's failure.
    state.setTop(0);
    try testing.expectError(
        error.RuntimeError,
        runReporting(&state, "return double_it('not a number')", "=callback", error.RuntimeError),
    );

    // Two arguments are the case that tells argument numbering from stack
    // numbering. If argument 1 were read as argument 2, this would answer the
    // other way round rather than raise.
    state.setTop(0);
    state.pushCFunction(&subtractArguments);
    state.setGlobal("take_two");
    try state.run("return take_two(20, 22)", "=callback");
    try testing.expectEqual(@as(luajit.Integer, -2), state.toInteger(1));

    // The same two arguments the other way round answer with the opposite
    // sign, so a swap of argument 1 and argument 2 cannot pass this. A sum
    // would not: `20 + 22` and `22 + 20` are one number, which is why this
    // C function subtracts.
    state.setTop(0);
    try state.run("return take_two(22, 20)", "=callback");
    try testing.expectEqual(@as(luajit.Integer, 2), state.toInteger(1));

    // And the arguments really are the ones the caller passed: a third
    // argument is not read at all.
    state.setTop(0);
    try state.run("return take_two(1, 2, 1000)", "=callback");
    try testing.expectEqual(@as(luajit.Integer, -1), state.toInteger(1));
}

/// The C function `take_two` is bound to: it reads two integer arguments
/// through `Args` and leaves their difference on the stack.
///
/// Subtracting is what lets argument 1 and argument 2 tell themselves apart to
/// the caller; the `Args` view is the same one `double_it` uses.
fn subtractArguments(l: ?*luajit.c.lua_State) callconv(.c) c_int {
    var state = luajit.State{ .raw = l };
    const args = luajit.Args{ .state = &state, .base = 1 };
    state.pushInteger(args.checkInteger(1) - args.checkInteger(2));
    return 1;
}

/// The C function `double_it` is bound to: it reads one integer argument
/// through `Args` and leaves its double on the stack.
fn doubleArgument(l: ?*luajit.c.lua_State) callconv(.c) c_int {
    // `Args` reads and writes through the state, so the wrapper this C function
    // builds is not a constant: it is the library's own pointer, borrowed for
    // the length of this call.
    var state = luajit.State{ .raw = l };
    // Argument numbers are relative to the frame Lua is calling in, and the C
    // API resolves them against `L->base` (`src/lj_err.c:1106`), which for a
    // C function is the slot argument 1 occupies. `Args` adds `base + n - 1`,
    // so the base is 1 and not `top()`: with two arguments `top()` would be 2,
    // and argument 1 would be read as argument 2.
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

    // While the state is open those blocks are live, and every one of them
    // went through this callback: the script it ran has no other way to get
    // memory.
    try testing.expect(counter.blocks.count() > 0);

    // Closing it hands all of them back, through the allocator installed at
    // that moment. Upstream holds itself to that: the close asserts that the
    // only bytes it did not give back are the global state block, and gives
    // that one back last (`src/lj_state.c:235-243`). So an empty book and a
    // zero difference are what a complete close means, not a tolerance.
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
    // The script above ran on this pair's memory, so there is something for
    // the ownership question below to be about.
    try testing.expect(first.blocks.count() > 0);

    // `lua_setallocf` assigns two fields and frees nothing
    // (`src/lj_api.c:1297-1302`), while the close releases every remaining
    // block through whichever pair is installed then (`src/lj_state.c:243`).
    // A pair swapped in therefore has to go straight back out before anything
    // is allocated, and the pair the swap handed back is what makes that
    // possible.
    const previous = state.setAllocator(&countingAlloc, &second);
    _ = state.setAllocator(previous.function, previous.user_data);

    // The second pair is on no block at all: it was installed for no
    // allocation, so every block the state still holds is the first pair's to
    // release. That is the whole ownership rule, and it is exactly what a
    // caller who allocates under a swapped-in pair loses.
    try testing.expectEqual(@as(usize, 0), second.blocks.count());
    try testing.expectEqual(@as(usize, 0), second.allocated);

    // A collection and a script after the round trip: blocks handed out and
    // given back, every one of them through the pair that owns them.
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
/// with `osz == 0`, `nsize == 0` is the only request to release, and a request
/// for more than nothing must come back with a pointer or the library raises
/// on the spot. Every block is recorded by the address it was handed out at
/// and the size *this* allocator gave it, because Zig's `free` and `realloc`
/// want the size that was allocated rather than the one Lua accounts for --
/// and because that pair is what `blocks` is checked against once the state is
/// closed. `osize` is not used: the address is the identity, and a resize that
/// moves the block moves the entry with it.
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
        // The old entry goes before the resize: the block may move, and an
        // entry left behind at the old address would be an allocation this
        // allocator no longer owns and could not release.
        const entry = self.blocks.fetchRemove(@intFromPtr(address)) orelse
            return null;
        const grown = self.allocator.realloc(blockAt(address, entry.value), nsize) catch {
            // The resize failed, so the block is still the one that was handed
            // out at its original size and it has to stay on the books.
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

/// The recorded block at `address`, at the length it was handed out with, so
/// that `free` and `realloc` see the same alignment the allocation had.
fn blockAt(address: *anyopaque, length: usize) Block {
    return @as([*]align(8) u8, @ptrCast(@alignCast(address)))[0..length];
}

test "a coroutine yields a value and resumes with another" {
    var state = openState();
    defer state.deinit();

    // `a + 1` is 11 and `b * 2` is 8; the point is that the two numbers cross
    // the boundary in opposite directions, one out through `yield` and one back
    // through the resume arguments.
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

    // A new coroutine's own stack is empty, so both the function to run and
    // the arguments it is resumed with go onto the coroutine and not onto the
    // parent: `lua_resume` runs whatever is below the `argument_count`
    // arguments on the stack of the thread it is given
    // (`src/lj_api.c:1100-1110`). `double_it` checks argument 1, so resuming
    // with nothing would raise inside it rather than answer.
    luajit.c.lua_pushcclosure(thread.raw, &doubleArgument, 0);
    luajit.c.lua_pushinteger(thread.raw, 21);

    try thread.@"resume"(1);
    try testing.expectEqual(@as(luajit.Index, luajit.c.LUA_OK), thread.status());
    try testing.expectEqual(@as(luajit.Integer, 42), luajit.c.lua_tointeger(thread.raw, -1));

    // The coroutine sits on the parent's stack, and the parent owns it; a
    // state that is closed takes it with it.
    state.setTop(0);
}

test "a full collection clears a weak table that still looks full" {
    var state = openState();
    defer state.deinit();

    // The two answers together are the claim: the entry is there before the
    // collection because nothing removed it, and gone after because the
    // collector did. Either half alone would be a weaker test.
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

    // `jit.status` is the library's own account of itself, and its first
    // *result* is whether the engine is on (`src/lib_jit.c:101-109`); the
    // rest are strings. It is an oracle independent of the call that changed
    // the state. It answers with several values, so the first is bound before
    // it is returned: `return f()` keeps only the last.
    //
    // Each chunk below empties the stack first. A protected call leaves what
    // the chunk returned above whatever was already there, so without the
    // clear, index 1 after the second run would still be the first run's
    // answer and every check after it would be reading a stale value.
    try testing.expect(luajit.jit.setEngine(&state, luajit.jit.on));
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=jit");
    try testing.expect(state.toBoolean(1));

    try testing.expect(luajit.jit.disable(&state));
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=jit");
    try testing.expect(!state.toBoolean(1));

    // Flushing is not the same as switching off: `LUAJIT_MODE_FLUSH` drops the
    // compiled traces and leaves the on/off flag alone
    // (`src/lj_dispatch.c:264-272`), which is the whole difference between the
    // two calls.
    try testing.expect(luajit.jit.flushEngine(&state));
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=jit");
    try testing.expect(!state.toBoolean(1));

    try testing.expect(luajit.jit.enable(&state));
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=jit");
    try testing.expect(state.toBoolean(1));

    // And the same flush while the engine is on leaves it on, which is the
    // other half of the difference.
    try testing.expect(luajit.jit.flushEngine(&state));
    state.setTop(0);
    try state.run("local on = jit.status() return on", "=jit");
    try testing.expect(state.toBoolean(1));

    // A script still runs normally with the engine off: switching the compiler
    // off is not switching the interpreter off. The sum of 1..1000 is 500500.
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

    // `luaJIT_setmode` answers 1 when it changed what it was asked to change
    // and 0 when the target is not one it can act on: `src/lj_dispatch.c:285`
    // for a value that is neither a Lua function nor a prototype, and `:326`
    // for the success return. The facade's boolean is that answer, not its
    // opposite.
    try state.load("local x = 1 return x", "=target");
    try testing.expect(luajit.jit.setMode(&state, -1, luajit.jit.func | luajit.jit.off));
    try testing.expect(luajit.jit.setMode(&state, -1, luajit.jit.func | luajit.jit.flush));
    state.setTop(0);

    // The same call on a C function is the failing case: there is no compiled
    // code there to drop and none can be made.
    state.pushCFunction(&doubleArgument);
    try testing.expect(!luajit.jit.setMode(&state, -1, luajit.jit.func | luajit.jit.off));
    state.setTop(0);

    // `LUAJIT_MODE_WRAPCFUNC` is a target mode of its own, and asking for a
    // wrapper with no C function to wrap is its documented failure
    // (`src/lj_dispatch.c:313-316`).
    try testing.expect(!luajit.jit.setMode(&state, 0, luajit.c.LUAJIT_MODE_WRAPCFUNC | luajit.jit.on));
}

test "bit operations agree with Zig's own integer operators" {
    var state = openState();
    defer state.deinit();

    // Each case is computed twice: once by LuaJIT's `bit`, once by Zig's `i32`
    // operators. Two implementations of the same definition agreeing is the
    // fixture; a value copied out of an earlier run would not be. Every case
    // here has an answer inside the signed 32-bit range, which is what makes it
    // a plain Lua number rather than an FFI cdata (`src/lib_bit.c:31-39`).
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

    // The operations that are not pairwise: an arithmetic shift sign-extends,
    // complementing zero is all ones, and a shift left by four is sixteen.
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
    // `State.openFfi`, not `require`: `luaL_openlibs` only preloads the FFI
    // for `require` (`src/lib_init.c:32-36`) and `luaopen_ffi` creates no
    // global of its own ("Note: no global \"ffi\" created!", `src/lib_ffi.c:855`),
    // so the global `ffi` below exists because this facade named it.
    state.openFfi();

    // This fork will not index a C symbol that nothing declared:
    // `lj_clib_index` looks the name up among the ctypes the declaration
    // parser created and raises `LJ_ERR_FFI_NODECL` -- "missing declaration
    // for symbol '%s'" -- when there is none (`src/lj_clib.c:348-350`,
    // `src/lj_errmsg.h:177`). There is no implicit declaration to fall back
    // on, so the prototype is written before the symbol is used. This is
    // glibc's own for `abs`.
    try state.run("ffi.cdef[[ int abs(int); ]]", "=ffi");
    state.setTop(0);

    // The answers are this test binary's own: a C `int` is four bytes and a
    // `double` eight on every target LuaJIT supports, and a pointer is whatever
    // this build's pointer is. LuaJIT has to agree with the build it was
    // compiled for, which is what the FFI's ABI is.
    //
    // `tonumber` around every `ffi.sizeof` and around the `abs` result is not
    // decoration. `lua_tonumberx` sets its flag only for a slot that already
    // holds a number or a string that scans as one, and answers 0 otherwise
    // (`src/lj_api.c:363-377`); a cdata is neither. The conversion has to
    // happen in Lua, where the cdata's `__tonumber` metamethod runs.
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

    // The symbol has to be declared before it can be indexed at all:
    // `lj_clib_index` raises `LJ_ERR_FFI_NODECL` for a name no declaration
    // made (`src/lj_clib.c:348-350`, `src/lj_errmsg.h:177`), so there is
    // nothing for a call to be checked against until `ffi.cdef` has run. This
    // is glibc's own prototype for `abs`, and it is what gives the call an
    // argument type to convert to.
    try state.run("ffi.cdef[[ int abs(int); ]]", "=ffi");
    state.setTop(0);

    // `abs` takes an `int`, and a string is not convertible to one.
    // `lj_cconv_ct_tv` hands a string on as `const char[]`
    // (`src/lj_cconv.c:596-600`), the conversion table has no entry from an
    // array to an integer outside a `ffi.cast` (`src/lj_cconv.c:224-225`), and
    // `cconv_err_conv` raises `LJ_ERR_FFI_BADCONV`
    // (`src/lj_cconv.c:21-35`, `src/lj_errmsg.h:165`). What is asserted is that
    // the raise came back as an error rather than as a converted value; the text
    // the library formats around it is upstream's wording and is not asserted.
    try testing.expectError(
        error.RuntimeError,
        runReporting(&state, "return ffi.C.abs(\"not a number\")", "=ffi", error.RuntimeError),
    );

    // The same call with the type it does take answers, and the state runs
    // the next chunk: the raise was a returned value, not an unwind. The
    // `tonumber` is `lua_tonumberx` refusing a cdata, as above.
    state.setTop(0);
    try state.run("return tonumber(ffi.C.abs(-42))", "=ffi");
    try testing.expectEqual(@as(luajit.Number, 42), state.toNumber(1));
}

test "openStringBuffer installs the dotted global that needs two tables" {
    var state = bareState();
    defer state.deinit();

    state.openLibs();
    state.openStringBuffer();

    // `string.buffer` is a LuaJIT extension (`src/lib_buffer.c`) and a dotted
    // name, so it cannot be set with one field call: the C API's setters do not
    // split on dots. Getting this wrong leaves `string.buffer` nil, and the
    // buffer extension silently absent from a build that compiled it. Nor is
    // this a presence claim: the methods are reached through the metatable
    // `buffer_new` attaches to every buffer it makes
    // (`src/lib_buffer.c:315-319`), and the table `openStringBuffer` names is
    // the module itself. That module table is not callable; its `new` entry is
    // the constructor, because buildvm registers each `LJLIB_CF` under its own
    // name with the module prefix stripped (`src/host/buildvm_lib.c:27-36`,
    // `src/lib_buffer.c:289`), which is the spelling upstream documents
    // (`doc/ext_buffer.html`).
//
    // Appending is a method on the buffer, not a second argument to the
    // constructor: `string.buffer.new(b, ...)` reads argument 1 as the size
    // (`src/lib_buffer.c:296-300`) and raises on a buffer, while `put` is
    // what appends and hands the buffer back for the next call
    // (`src/lib_buffer.c:116-150`).
    //
    // The five bytes below are five bytes, NUL included. `put` appends a
    // string's length rather than up to its NUL (`src/lib_buffer.c:123-124`),
    // `#b` is `__len` counting the same bytes (`src/lib_buffer.c:273-278`),
    // and `tostring` is `__tostring` building a string from them
    // (`src/lib_buffer.c:265-271`) without moving the read pointer -- so
    // asking for the text does not consume it and `#b` after it is still 5.
    // The `\x00` is two hex digits and no more (`src/lj_lex.c:215-226`).
    try runReporting(&state,
        \\local b = string.buffer.new(16)
        \\b:put("ab")
        \\b:put("\x00cd")
        \\return tostring(b), #b
    , "=buffer", null);
    try testing.expectEqualSlices(u8, "ab\x00cd", state.toString(1).slice());
    try testing.expectEqual(@as(luajit.Integer, 5), state.toInteger(2));
}