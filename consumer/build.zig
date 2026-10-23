// SPDX-License-Identifier: MIT
// See ../FORK-LICENSE.md for what that identifier covers.
//! Consumer package build graph using the published `luajit` module.

const std = @import("std");
const ExecutorFlags = struct {
    darling: bool,
    qemu: bool,
    rosetta: bool,
    wasmtime: bool,
    wine: bool,
};

/// Uses Zig's target and executor rules to select run or install.
fn hostCanExecute(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    flags: ExecutorFlags,
) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;

    // This filesystem observation has no tracked input.
    b.graph.poisonCache();
    const executor = std.zig.system.getExternalExecutor(b.graph.io, candidate, .{
        .host_cpu_arch = host.cpu.arch,
        .host_os_tag = host.os.tag,
        .link_mode = .dynamic,
        .link_libc = true,
    });
    return switch (executor) {
        .native => true,
        .rosetta => flags.rosetta,
        // The nested build cannot inherit the parent's configured libc runtimes.
        .qemu => flags.qemu and !candidate.isGnuLibC(),
        .wine => flags.wine,
        .wasmtime => flags.wasmtime,
        .darling => flags.darling,
        .bad_dl, .bad_os_or_cpu => false,
    };
}

fn executorFlags(b: *std.Build) ExecutorFlags {
    return .{
        .darling = b.option(bool, "consumer-run-darling", "Internal consumer run selection.") orelse false,
        .qemu = b.option(bool, "consumer-run-qemu", "Internal consumer run selection.") orelse false,
        .rosetta = b.option(bool, "consumer-run-rosetta", "Internal consumer run selection.") orelse false,
        .wasmtime = b.option(bool, "consumer-run-wasmtime", "Internal consumer run selection.") orelse false,
        .wine = b.option(bool, "consumer-run-wine", "Internal consumer run selection.") orelse false,
    };
}

pub fn build(b: *std.Build) void {
    const flags = executorFlags(b);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forward only supplied options so the dependency keeps its own defaults.
    const linkage = b.option(
        std.lang.LinkMode,
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
        .@"lua-root" = lua_root,
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
    run_exe.addPassthruArgs();
    const run_step = b.step("run", "Build and run the consumer program");
    run_step.dependOn(&run_exe.step);

    const consumer_step = b.step(
        "consumer",
        "Run the consumer when a selected executor can execute it; otherwise install it",
    );
    if (hostCanExecute(b, target, flags)) {
        consumer_step.dependOn(&run_exe.step);
    } else {
        consumer_step.dependOn(b.getInstallStep());
    }

    // The dependency selects its build-cache loader path for `run`; installed binaries use its install-tree path.
    // Zig's run step adds no loader search path.
}
