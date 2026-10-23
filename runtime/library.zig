// SPDX-License-Identifier: MIT
//! LuaJIT-specific loader descriptor for synchronization names and provider validation.
//! Providers must match the translated ABI and release symbol.

const rt = @import("rt");

/// Namespaced callbacks from `runtime/sync.c`; names must match `runtime/graph.zig`.
/// The loader uses these callbacks to coordinate concurrent load attempts.
pub const Sync = struct {
    extern fn luajit_rt_lock() void;
    extern fn luajit_rt_unlock() void;
    extern fn luajit_rt_wait() void;
    extern fn luajit_rt_broadcast() void;
    // Matches C's `unsigned long long` on supported LuaJIT targets.
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

/// Builds the loader configuration for this SDK's generated dispatch.
/// The dispatch type is passed in, so this descriptor does not import it.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Library name used in the pre-load panic.
        pub const library_name = "luajit";

        /// Table and exports to fill, generated from the translated header.
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

        /// Creates a temporary state and compares `lua_version`'s pointed-to number
        /// with the translated `LUA_VERSION_NUM` before table publication.
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
