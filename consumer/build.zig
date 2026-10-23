// SPDX-License-Identifier: MIT
// See ../FORK-LICENSE.md for what that identifier covers.
//! Consumer package build graph using the published `luajit` module.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forward only supplied options so the dependency keeps its own defaults.
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Which delivery of libluajit to check: static archive or shared " ++
            "object. Forwarded to the dependency unchanged; it decides the " ++
            "artifact, never anything in this package. Left unset, the " ++
            "library's own default applies.",
    );
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Check the dependency's runtime-loading dispatch instead of a linked " ++
            "one. Forwarded to the dependency. A program built this way has to " ++
            "name a provider with an explicit load() before any native call, " ++
            "which is src/main.zig's business and not this file's: it reads " ++
            "`--provider <path>` below, or LUAJIT_TEST_PROVIDER from the " ++
            "environment. Left unset, the library's own default applies.",
    );

    // Forward `lua-root` unchanged; an unset value leaves installation policy to the library.
    const lua_root = b.option(
        []const u8,
        "lua-root",
        "Absolute install root compiled into the library as LUA_ROOT and " ++
            "LUA_LJDIR (src/Makefile:290-304). Forwarded to the dependency " ++
            "unchanged. Left unset, the library's own default applies.",
    );

    const dep = b.dependency("luajit", .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime = runtime_loaded,
        .lua_root = lua_root,
    });

    // The dependency supplies C linkage; do not mask a missing declaration here.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("luajit", dep.module("luajit"));

    const exe = b.addExecutable(.{
        .name = "luajit-consumer",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.has_side_effects = true;
    // Forward run arguments so the runtime provider path reaches the consumer.
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Build and run the consumer program");
    run_step.dependOn(&run_exe.step);

    // The dependency selects its build-cache loader path for `run`; installed binaries use its install-tree path.
    // Zig's run step adds no loader search path.
}
