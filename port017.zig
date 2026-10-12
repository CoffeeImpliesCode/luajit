// SPDX-License-Identifier: MIT
const std = @import("std");

fn driver(b: *std.Build, mode: []const u8) *std.Build.Step.Run {
    const executable = b.addExecutable(.{
        .name = b.fmt("port017-{s}", .{mode}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("port017_make.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const run = b.addRunArtifact(executable);
    run.addArg(mode);
    return run;
}

fn libcRuntimes(b: *std.Build) std.Build.LazyPath {
    const executable = b.addExecutable(.{
        .name = "port017-runtimes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("port017_runtimes.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const run = b.addRunArtifact(executable);
    run.enableProtocolMode();
    run.addDirectoryArg2(.{ .relative = .{ .base = .libc_runtimes } }, .{});
    return run.addOutputFileArg("libc-runtimes");
}

pub fn consumer(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Run {
    const run = driver(b, "consumer");
    run.setCwd(b.path("consumer"));
    run.addArgs(&.{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi), target.result.dynamic_linker.get() orelse "" });
    run.addDirectoryArg2(b.path(""), .{ .make_absolute = true });
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{ .make_absolute = true });
    run.addThirdPartyEnabledArgDarling(.{ .enabled = "-fdarling" });
    run.addThirdPartyEnabledArgQemu(.{ .enabled = "-fqemu" });
    run.addThirdPartyEnabledArgRosetta(.{ .enabled = "-frosetta" });
    run.addThirdPartyEnabledArgWasmtime(.{ .enabled = "-fwasmtime" });
    run.addThirdPartyEnabledArgWine(.{ .enabled = "-fwine" });
    run.addFileContentArg2(libcRuntimes(b), .{ .prefix = "--libc-runtimes=" });
    run.addDirectoryArg2(.{ .relative = .{ .base = .global_cache } }, .{
        .prefix = "--global-cache-dir=",
        .make_absolute = true,
    });
    run.addArg("--");
    run.addFileArg(.zig_exe);
    run.addArg("build");
    run.addArg("--cache-dir");
    run.addDirectoryArg2(.{ .relative = .{ .base = .local_cache, .sub_path = "consumer" } }, .{
        .make_absolute = true,
    });
    return run;
}

pub fn rootHeader(b: *std.Build) std.Build.LazyPath {
    // A dependency's prefix is a disposable cache directory, not a Lua root.
    if (b.pkg_hash.len != 0) return b.addWriteFiles().add("lua_install_root.h", "");
    const run = driver(b, "root");
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{});
    run.addDirectoryArg2(.cache_root, .{ .make_absolute = true });
    return run.addOutputFileArg("lua_install_root.h");
}

pub fn generator(b: *std.Build, artifact: *std.Build.Step.Compile, emulator: []const u8) *std.Build.Step.Run {
    const run = driver(b, "generator");
    run.addArg(emulator);
    run.addThirdPartyEnabledArgQemu(.{ .enabled = "--qemu" });
    run.addArtifactArg(artifact);
    return run;
}
