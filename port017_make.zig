// SPDX-License-Identifier: MIT
const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (std.mem.eql(u8, args[1], "root")) {
        const prefix = installPrefix(args[2], init.environ_map);
        const cache = std.mem.trimEnd(u8, args[3], "/\\");
        const inside_cache = prefix.len > cache.len and
            std.mem.startsWith(u8, prefix, cache) and
            std.fs.path.isSep(prefix[cache.len]);
        const content = if (std.fs.path.isAbsolute(prefix) and !inside_cache)
            try arena.print("#define LUA_ROOT \"{s}\"\n#define LUA_MULTILIB \"lib\"\n#define LUA_LJDIR \"{s}/share/luajit-2.1\"\n", .{ prefix, prefix })
        else
            "";
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[4], .data = content });
        return;
    }
    var command: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, args[1], "generator")) {
        var index: usize = 3;
        if (std.mem.eql(u8, args[index], "--qemu")) {
            try command.append(arena, args[2]);
            index += 1;
        }
        try command.appendSlice(arena, args[index..]);
    } else {
        var target: std.Target = undefined;
        target.cpu.arch = std.meta.stringToEnum(std.Target.Cpu.Arch, args[2]).?;
        target.os.tag = std.meta.stringToEnum(std.Target.Os.Tag, args[3]).?;
        target.abi = std.meta.stringToEnum(std.Target.Abi, args[4]).?;
        target.dynamic_linker = .none;
        if (args[5].len != 0) target.dynamic_linker.set(args[5]);
        const root = args[6];
        const prefix = installPrefix(args[7], init.environ_map);
        var darling = false;
        var qemu = false;
        var wasmtime = false;
        var wine = false;
        var runtimes: ?[]const u8 = null;
        var start: usize = 8;
        while (!std.mem.eql(u8, args[start], "--")) : (start += 1) {
            const arg = args[start];
            if (std.mem.eql(u8, arg, "-fdarling")) darling = true;
            if (std.mem.eql(u8, arg, "-fqemu")) qemu = true;
            if (std.mem.eql(u8, arg, "-fwasmtime")) wasmtime = true;
            if (std.mem.eql(u8, arg, "-fwine")) wine = true;
            if (std.mem.startsWith(u8, arg, "--libc-runtimes=") and arg.len > 16) runtimes = arg[16..];
            if (std.mem.startsWith(u8, arg, "--global-cache-dir=")) {
                try init.environ_map.put("ZIG_GLOBAL_CACHE_DIR", arg[19..]);
            }
        }
        const can_run = switch (std.zig.system.getExternalExecutor(io, &target, .{
            .host_cpu_arch = builtin.cpu.arch,
            .host_os_tag = builtin.os.tag,
            .qemu_fixes_dl = target.isGnuLibC() and runtimes != null,
            .link_mode = .dynamic,
            .link_libc = true,
        })) {
            .native => true,
            .rosetta => true,
            .qemu => qemu and !(target.isGnuLibC() and runtimes == null),
            .wine => wine,
            .wasmtime => wasmtime,
            .darling => darling,
            .bad_dl, .bad_os_or_cpu => false,
        };
        start += 1;
        try command.appendSlice(arena, args[start .. start + 2]);
        try command.append(arena, if (can_run) "run" else "install");
        // Forward the same resolved Lua root that the outer native graph uses.
        const build_args = args[start + 2 ..];
        const explicit_root = for (build_args) |arg| {
            if (std.mem.startsWith(u8, arg, "-Dlua-root=")) break true;
        } else false;
        const cache = std.fs.path.dirname(build_args[1]) orelse build_args[1];
        const inside_cache = prefix.len > cache.len and
            std.mem.startsWith(u8, prefix, cache) and std.fs.path.isSep(prefix[cache.len]);
        if (!explicit_root and std.fs.path.isAbsolute(prefix) and !inside_cache) {
            try command.append(arena, try arena.print("-Dlua-root={s}", .{prefix}));
        }
        for (args[8 .. start - 1]) |arg| {
            if (std.mem.startsWith(u8, arg, "--global-cache-dir=")) continue;
            if (std.mem.startsWith(u8, arg, "--libc-runtimes=")) {
                if (arg.len > 16) try command.appendSlice(arena, &.{ "--libc-runtimes", arg[16..] });
            } else {
                try command.append(arena, arg);
            }
        }
        const default_prefix = try std.fs.path.join(arena, &.{ root, "zig-out" });
        if (!std.mem.eql(u8, prefix, default_prefix)) {
            try command.appendSlice(arena, &.{ "--prefix", prefix });
        }
        try command.appendSlice(arena, args[start + 2 ..]);
    }
    var child = try std.process.spawn(io, .{ .argv = command.items, .environ_map = init.environ_map });
    switch (try child.wait(io)) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}

fn installPrefix(path: []const u8, environ: *const std.process.Environ.Map) []const u8 {
    const dest_dir = std.mem.trimEnd(u8, environ.get("DESTDIR") orelse return path, "/\\");
    if (dest_dir.len != 0 and path.len > dest_dir.len and
        std.mem.startsWith(u8, path, dest_dir) and std.fs.path.isSep(path[dest_dir.len]))
    {
        return path[dest_dir.len..];
    }
    return path;
}
