// SPDX-License-Identifier: MIT
// See ../FORK-LICENSE.md for what that identifier covers.
//
//! Build wiring for the separate `consumer/` package.
//!
//! This package exists to prove one thing: that a dependent needs only
//! `dep.module("luajit")` and gets a working, correctly linked LuaJIT 5.1.
//! If the facade module stopped carrying its C artifact, or the translated
//! headers stopped matching the C sources, or the `luajit` module stopped
//! resolving by name, this would stop building or stop producing the answers
//! its program checks - and nothing inside the library would notice.
//!
//! `src/main.zig` is the API role's file. This file is only the graph that
//! builds it, and it deliberately repeats almost nothing: the library decides
//! which artifact is delivered, which platform macros it was compiled with and
//! which headers describe it, and this package learns all of that through the
//! dependency rather than by restating it.
//!
//! `zig build run` runs it. The parent package's `zig build consumer` builds
//! this package as a nested build for the selected target, linkage, dispatch
//! mode and install root, and asks it for `run` or `install` according to what
//! this host can execute, so `zig build consumer -Dlinkage=dynamic` really does
//! check the shared object and not the default archive.
//!
//! The library manifest carries its own `.fingerprint`
//! (`../build.zig.zon:15`), and this package carries a different one of its own
//! (`build.zig.zon:6`) because it is a different package with a different
//! name. A path dependency's fingerprint is not restated anywhere below, and
//! this build must not invent or edit one.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The delivery and dispatch options are declared here rather than ignored,
    // so `zig build run -Dlinkage=dynamic` checks the shared object instead of
    // silently checking the default archive, and so the parent package's
    // `zig build consumer` can pass a configuration through to the dependency
    // instead of dropping it on the floor.
    //
    // Both are forwarded *unset*, never defaulted here. `std.Build` records a
    // dependency argument only when it carries a value -- the enum and bool arms
    // are guarded by `if (maybe_value) |v|` -- and an optional is unwrapped
    // before that, so a `null` here is not forwarded at all and the library
    // resolves its own `-Dlinkage` policy (`build.zig:194-200`) and its own
    // `-Druntime` policy (`build.zig:215-221`). A default written in this
    // package would be a second answer to a question that belongs to the
    // library, and on a target where the library's default is not `static` it
    // would be a static substitution.
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

    // The install root the library compiles into `LUA_ROOT`, `LUA_LJDIR` and
    // `LUA_MULTILIB` (`src/Makefile:288-304`). Declared here for the same
    // reason as `linkage` and `runtime`, and forwarded unchanged: the parent
    // package resolves it once -- `lua_root_option orelse install_root(b)` --
    // and what this package exists to show is that a dependent gets the library
    // the parent configured. Forwarded *unset* like the other two, so an
    // unresolved root leaves the library to its own policy
    // (`build.zig:275-295`) rather than substituting one here.
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

    // No `link_libc` here on purpose. The C requirement belongs to the library
    // module, which carries it; a dependent states its own, and this program
    // needs nothing beyond what the library already brings. Adding it here would
    // hide a library that forgot to declare it.
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
    // Forwarded so `zig build run -Druntime=true -- --provider <path>` reaches
    // `src/main.zig`, which reads exactly that and refuses to guess without.
    // With no arguments this is inert, so a linked run is unchanged.
    run_exe.addPassthruArgs();
    const run_step = b.step("run", "Build and run the consumer program");
    run_step.dependOn(&run_exe.step);

    // Two loaders, and this program is the build-cache one. The facade module
    // it imports is linked as `Loader.build_cache`, so the build records where
    // the shared object really is and nothing is added here.
    // `$ORIGIN/../lib` -- `@loader_path/../lib` on Mach-O -- is
    // `Loader.install_tree`, and it belongs to `bin/luajit` alone: the program
    // `zig build install` writes into `bin/`, linked through a module of its
    // own. See `linkForLoader` in build_support/graph.zig.
    // Zig's run step sets no loader search path of its own.
}
