// SPDX-License-Identifier: MIT
//
//! LuaJIT's side of the runtime loader: the names its synchronization binding
//! has, and what it requires of a provider beyond resolving its symbols.
//!
//! Everything else about the runtime route is generic. `runtime/loader.zig` is
//! the state machine and the platform layer; `runtime/generate.zig` builds the
//! dispatch from whatever the translation step actually produced;
//! `runtime/graph.zig` wires them together. This file is what makes them
//! LuaJIT's, and it is the file another SDK replaces.
//!
//! ## What a provider must be
//!
//! Every entry point `src/lua.h`, `src/lauxlib.h`, `src/lualib.h` and the
//! generated `src/luajit.h` declare, except the one `runtime/graph.zig` names as
//! optional: `lua_setlevel` is declared at `src/lua.h:300` and defined nowhere
//! in this tree, so no provider can export it.
//!
//! That set includes the generated version symbol, and it is the strongest
//! thing in this file. `src/luajit_rolling.h:35` defines `LUAJIT_VERSION_SYM`
//! as `luaJIT_version_2_1_` followed by the rolling release identifier, and
//! `src/host/genversion.lua` fills that identifier in from `.relver` when it
//! generates `src/luajit.h`. `src/lj_dispatch.c:330` defines the symbol under
//! the same macro, so the library exports exactly the name its own header
//! names. Requiring that name is upstream's own version enforcement, performed
//! by the linker in a dynamic build (`src/luajit.c:533`) and by this loader
//! through the symbol table here: a provider built from a different rolling
//! snapshot does not export this name and is refused with `MissingSymbol`
//! before any of its code runs. No check below adds to that.
//!
//! ## The ABI boundary, stated honestly
//!
//! The provider must agree with the translated header on four things, all of
//! which the header itself fixes rather than this file:
//!
//!  * `lua_Number` is `double` and `lua_Integer` is `ptrdiff_t`
//!    (`src/luaconf.h:106` and `src/luaconf.h:119`). `ptrdiff_t` is 32 bits on
//!    a 32-bit target and 64 on a 64-bit one, so `lua_Integer` is not one width
//!    across the supported targets; a provider built for another pointer width
//!    is not a provider for this header.
//!  * `luaL_Buffer`'s layout, which is the `lua_State *`, two scalars and a
//!    `LUAL_BUFFERSIZE` byte array (`src/lauxlib.h:135-140`), where
//!    `LUAL_BUFFERSIZE` is `BUFSIZ > 16384 ? 8192 : BUFSIZ`
//!    (`src/luaconf.h:113`). It follows from `BUFSIZ`, so a provider compiled
//!    where `BUFSIZ` is larger than 16384 has a different struct size. That is
//!    upstream's ABI, not this fork's, and it is why the translation step is
//!    given the target's own headers rather than a fork-defined `BUFSIZ`.
//!  * The scalar widths and calling conventions of the target itself, which is
//!    what "the C ABI" means for a provider reached through `dlopen`.
//!  * The architecture. LuaJIT 2.1 compiles for x86, x64, arm, arm64, ppc,
//!    mips32 and mips64 and for nothing else: `src/lj_arch.h:51-69` selects one
//!    of those or fails the build. A wasm32 or riscv64 provider cannot exist.
//!
//! What is deliberately *not* part of the boundary:
//!
//!  * `LJ_GC64` (`src/lj_arch.h:596-602`). It is a build-time choice, on by
//!    default for 64-bit targets and refused on macOS (`src/lj_arch.h:219`), and
//!    it changes `GCobj` and `GCRef` inside the library. Nothing in the four
//!    public headers depends on it, so a provider built either way presents the
//!    same declarations and this route cannot tell them apart. A caller that
//!    cares reads `jit.arch` or `jit.os` from Lua, not the collector's mode.
//!  * Which JIT backend the provider was built with. `jit.on`/`jit.off` and the
//!    trace flushes behave the same through the same entry points.
//!  * Whether FFI was compiled in. `LJ_HASFFI` (`src/lj_arch.h:617-622`) decides
//!    whether `require "ffi"` succeeds, and that is a property of the provider
//!    a caller discovers by using it, not something this loader can check
//!    without a state and a `require`.
//!
//! ## What is actually checked
//!
//! Resolving the symbols and translating the header are the boundary. They are
//! not proof that a provider is compatible, and this file does not pretend to
//! add one. The one check below asks a provider to answer a question: it creates
//! a state through `luaL_newstate()`, reads the number `lua_version` points at,
//! and closes the state again. That proves the library loaded, allocated a
//! state and reports the `LUA_VERSION_NUM` these headers were translated from,
//! rather than another Lua release's. PUC-Rio's Lua 5.5 reports 505, so a 5.5
//! provider is refused by value instead of by symbol count.
//!
//! It does not prove the collector mode, the number mode, the architecture or
//! the `luaL_Buffer` size, and a caller who needs those to match has to select a
//! provider that was built for this header.

const rt = @import("rt");

/// The synchronization this loader calls, bound by exact name.
///
/// The names below are `runtime/sync.h` compiled with
/// `RT_SYNC_PREFIX=luajit_rt`, which is what `runtime/graph.zig` passes. Two
/// spellings of that prefix have to agree: this file names the symbols, and
/// graph.zig defines the macro. A build where they disagree does not link, and
/// that is the whole error report: there is no runtime path that could hide it.
///
/// The core in `runtime/loader.zig` never names a symbol of its own, which is
/// what lets two SDKs, or two configurations of one SDK, hold their own loader
/// state in one process without sharing any of it.
///
/// Five functions, and that is the surface `runtime/sync.h` actually declares
/// (`RT_FN(lock)`, `RT_FN(unlock)`, `RT_FN(wait)`, `RT_FN(broadcast)`,
/// `RT_FN(thread_self)`; the prefix and the names are joined by `sync.h`'s own
/// `RT_JOIN(RT_SYNC_PREFIX, RT_JOIN(_, name))`, which is why these are
/// `luajit_rt_...` and not `luajit_rt...`). The core's own documentation at
/// `runtime/loader.zig:307` also lists `signal`, but nothing in the core calls
/// it and no such function is declared in `sync.h` or defined in `sync.c`, so
/// there is no symbol here to bind and binding one anyway would break the very
/// agreement this comment describes. `broadcast` wakes every waiter and is what
/// the core uses at every wake-up point; a single-waiter `signal` would be a
/// sixth entry in a header this file does not own.
pub const Sync = struct {
    extern fn luajit_rt_lock() void;
    extern fn luajit_rt_unlock() void;
    extern fn luajit_rt_wait() void;
    extern fn luajit_rt_broadcast() void;
    // `unsigned long long`. Declared as u64, which is the same type in every
    // ABI this SDK supports: 64 bits on x86_64, arm64, ppc64 and mips64.
    extern fn luajit_rt_thread_self() u64;

    pub fn lock() void {
        luajit_rt_lock();
    }
    pub fn unlock() void {
        luajit_rt_unlock();
    }
    pub fn wait() void {
        luajit_rt_wait();
    }
    pub fn broadcast() void {
        luajit_rt_broadcast();
    }
    pub fn threadSelf() u64 {
        return luajit_rt_thread_self();
    }
};

/// The loader's configuration for this SDK, given the dispatch that owns the
/// table.
///
/// `dispatch` is the generated module, passed as a type by the dispatch itself
/// so that this file never has to import it. The direction is one-way on
/// purpose: the descriptor knows what the loader needs, the dispatch knows what
/// the header said, and neither imports the other.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Named in the pre-load panic, so the message says which library was
        /// reached for before it was loaded.
        pub const library_name = "luajit";

        /// The table the generated dispatch declares, and the symbols it needs
        /// to fill it. Both come from the translated header, not from this file.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// The project's namespaced synchronization binding.
        pub const sync = Sync;

        pub fn tablePtr() *table {
            return dispatch.tablePtr();
        }

        pub fn ready() *rt.Ready {
            return &dispatch.ready;
        }

        pub fn assign(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assign(index, dst, address);
        }

        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// The one library-specific check, run after every symbol resolved and
        /// before anything is published.
        ///
        /// It asks the provider to identify itself. A state is created and
        /// closed inside this call, so the cost is one allocation the provider
        /// makes and immediately releases; a provider that cannot even do that
        /// is not a Lua library, and nothing else here would find out.
        ///
        /// `lua_version` does **not** answer a string. `src/lua.h:351` declares
        /// it as `const lua_Number *`, and `src/lj_api.c:136-140` returns the
        /// address of a static `lua_Number` holding `LUA_VERSION_NUM`. So the
        /// comparison is against that number, and both sides of it come from
        /// the translation this build selected rather than from a literal
        /// written here: `dispatch.LUA_VERSION_NUM` is `src/lua.h:21` and
        /// `dispatch.lua_Number` is `src/luaconf.h:119`. Reading those eight
        /// bytes as text would compare 501.0's little-endian spelling against
        /// `Lua 5.1` and refuse every provider, including the right one.
        pub fn validate(dst: *const table) ?[]const u8 {
            const expected: dispatch.lua_Number = @floatFromInt(dispatch.LUA_VERSION_NUM);

            const state = dst.luaL_newstate() orelse
                return "luaL_newstate() answered NULL, so this provider cannot " ++
                    "create a Lua state at all";
            defer dst.lua_close(state);

            const reported = dst.lua_version(state) orelse
                return "lua_version() answered NULL, so this provider cannot " ++
                    "name the Lua release its states belong to";
            if (reported.* != expected) {
                return "lua_version() reports a LUA_VERSION_NUM other than the " ++
                    "one this header was translated from, so this provider is " ++
                    "not the Lua 5.1 library these declarations describe";
            }
            return null;
        }
    };
}