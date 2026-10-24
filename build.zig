// SPDX-License-Identifier: MIT
//! Zig 0.17.0 build graph for LuaJIT 2.1 rolling sources.
//! `graph.releaseVersion` reads the checked-in `.relver` stamp.
//! Do not add system-library mode: headers, VM tables, and ABI version must match.

const std = @import("std");

const graph = @import("build_support/graph.zig");
const sources = @import("build_support/sources.zig");
const abi = @import("build_support/abi.zig");

const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

/// Detects explicit `-Dtarget`; the resolved query cannot distinguish a host
/// target from no target option.
fn target_was_named(b: *const std.Build) bool {
    return b.user_input_options.contains("target");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Static is the default; upstream's mixed mode is not one artifact.
    const linkage = b.option(
        std.lang.LinkMode,
        "linkage",
        "Build libluajit-5.1 as a static archive (the default) or a shared library. " ++
            "This selects the kind of artifact `zig build install` writes and, on " ++
            "Windows, whether -DLUA_BUILD_AS_DLL applies (src/Makefile:559-575).",
    ) orelse .static;

    // Runtime dispatch is independent of artifact linkage; the library is built
    // either way because runtime mode loads that artifact.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native symbols through the platform loader at run time " ++
            "instead of linking libluajit-5.1 into the facade. Requires the " ++
            "driver-owned runtime/{loader.zig,sync.c,sync.h,generate.zig}.",
    ) orelse false;

    // Embed only an explicit absolute root; relative runtime paths depend on the cwd.
    const lua_root_option = b.option(
        []const u8,
        "lua-root",
        "Absolute install root compiled into the binary as LUA_ROOT and LUA_LJDIR " ++
            "(src/Makefile:290-304). When omitted, upstream's documented " ++
            "distribution layout applies (doc/install.html#distro). It is " ++
            "deliberately not written into luajit.pc: that file names its own " ++
            "location instead, so it still resolves after the tree is copied. " ++
            "See addPkgConfig.",
    );
    if (lua_root_option) |root| {
        if (!std.fs.path.isAbsolute(root)) {
            std.debug.panic(
                "luajit: -Dlua-root must be an absolute path, got '{s}'. " ++
                    "LUA_PATH_DEFAULT (luaconf.h:63-64) is a runtime search path.",
                .{root},
            );
        }
    }
    const lua_root = lua_root_option;

    // Reject architectures outside LuaJIT's supported set.
    const selection = abi.select(target.result) catch |err| switch (err) {
        error.Ppc64NotSupported => std.debug.panic(
            "luajit: {s}: {s} (lj_arch.h:369-370)",
            .{ @tagName(target.result.cpu.arch), "PowerPC 64-bit is not supported by LuaJIT" },
        ),
        error.ArchitectureNotSupported => std.debug.panic(
            "luajit: {s}: {s} (lj_arch.h:69)",
            .{ @tagName(target.result.cpu.arch), abi.architecture_not_supported_message },
        ),
    };

    // Read the upstream rolling-release stamp once for all generated names.
    const release_version = graph.releaseVersion(b);

    const native = graph.addGraph(b, .{
        .target = target,
        .optimize = optimize,
        .public = true,
        .name_prefix = graph.artifact_name,
        .linkage = linkage,
        .release_version = release_version,
        .with_cli = true,
        // The self-check uses the cache CLI; install its Lua modules first.
        .for_cache_runs = true,
        .lua_root = lua_root,
        .runtime_loaded = runtime_loaded,
    }) catch unreachable;

    addInstall(b, native, selection, target.result, release_version);

    // Run the cache-built CLI after installing its Lua module tree.
    const run_selfcheck = b.addRunArtifact(native.run_cli.?);
    run_selfcheck.setName("luajit native self-check");
    run_selfcheck.addFileArg2(b.path("build_support/native_selfcheck.lua"), .{});
    if (target.result.isMuslLibC() and !target.query.isNativeAbi() and linkage == .static) {
        run_selfcheck.addArg("--static-musl");
    }
    // Force execution; a cached run result would not prove the CLI ran.
    run_selfcheck.has_side_effects = true;

    // The CLI resolves `jit.*` modules from the installed tree.
    run_selfcheck.step.dependOn(b.getInstallStep());
    b.step(
        "native-test",
        "Run the delivered luajit CLI and check the JIT, the FFI and the jit modules",
    ).dependOn(&run_selfcheck.step);

    addHeaderCheck(b, linkage, selection);

    // The default install step compiles the CLI; execution belongs to native-test.
    b.getInstallStep().dependOn(&native.cli.?.step);

    const facade_tests = addFacadeTests(b, target, optimize, native.module.?, "luajit-tests");
    const run_tests = b.addRunArtifact(facade_tests);
    run_tests.has_side_effects = true;
    b.step("test", "Run the LuaJIT facade tests for the selected target")
        .dependOn(&run_tests.step);

    const smoke = b.addExecutable(.{
        .name = "luajit-smoke",
        .root_module = facadeProgram(b, target, optimize, native.module.?, "smoke.zig"),
    });
    const run_smoke = b.addRunArtifact(smoke);
    run_smoke.has_side_effects = true;
    b.step("smoke", "Run the LuaJIT smoke example").dependOn(&run_smoke.step);

    // Run the consumer separately so dependency resolution uses its manifest.
    b.step("consumer", "Build the separate consumer/ package for the selected " ++
        "target, and run it when this host can execute it").dependOn(&runConsumer(b, target, optimize, linkage, runtime_loaded, lua_root).step);

    const check_step = b.step(
        "check",
        "Compile the native graph, the facade, the tests and the smoke example " ++
            "for the six required cross targets, running nothing. For the " ++
            "two architectures LuaJIT 2.1 does not support, assert upstream's refusal.",
    );
    if (target_was_named(b)) {
        addTargetCheck(b, check_step, target.query, optimize, linkage, lua_root, runtime_loaded, release_version);
    } else {
        for (check_targets) |query| {
            addTargetCheck(b, check_step, query, optimize, linkage, lua_root, runtime_loaded, release_version);
        }
    }
}

/// Uses the facade and links libc explicitly to test the module contract.
fn facadeProgram(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    facade: *std.Build.Module,
    source: []const u8,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("luajit", facade);
    return mod;
}

fn addFacadeTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    facade: *std.Build.Module,
    name: []const u8,
) *std.Build.Step.Compile {
    const tests = b.addTest(.{
        .name = name,
        .root_module = facadeProgram(b, target, optimize, facade, "tests.zig"),
    });
    tests.root_module.addCSourceFile(.{
        .file = b.path("build_support/ffi_test.c"),
        .flags = &.{"-fno-builtin-abs"},
    });
    return tests;
}

/// Compiles the graph and roots for one target; cross-compiled binaries do not
/// execute here.
fn addTargetCheck(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    lua_root: ?[]const u8,
    runtime_loaded: bool,
    release_version: []const u8,
) void {
    const resolved = b.resolveTargetQuery(query);
    const triple = resolved.result.zigTriple(b.allocator) catch @panic("luajit: unspellable target");

    // Require LuaJIT's own unsupported-architecture error instead of skipping.
    _ = abi.select(resolved.result) catch |err| switch (err) {
        error.Ppc64NotSupported, error.ArchitectureNotSupported => {
            step.dependOn(&addArchitectureRefusalCheck(b, resolved, triple, err).step);
            return;
        },
    };

    const native = graph.addGraph(b, .{
        .target = resolved,
        .optimize = optimize,
        // Keep per-target modules private to avoid cross-target name collisions.
        .public = false,
        .name_prefix = b.fmt("luajit-{s}", .{triple}),
        .linkage = linkage,
        .release_version = release_version,
        .with_cli = true,
        .lua_root = lua_root,
        // Match the published graph's runtime-loading configuration.
        .runtime_loaded = runtime_loaded,
    }) catch unreachable;

    step.dependOn(&native.library.step);
    step.dependOn(&native.cli.?.step);
    step.dependOn(&addFacadeTests(
        b,
        resolved,
        optimize,
        native.module.?,
        b.fmt("luajit-tests-{s}", .{triple}),
    ).step);
    step.dependOn(&b.addExecutable(.{
        .name = b.fmt("luajit-smoke-{s}", .{triple}),
        .root_module = facadeProgram(b, resolved, optimize, native.module.?, "smoke.zig"),
    }).step);
}

/// Runs the consumer separately to avoid a manifest dependency cycle.
///
/// Forwards the target query, CPU selection, requested executors, cache paths,
/// prefix, and runtime options so the child checks this configuration.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
    lua_root: ?[]const u8,
) *std.Build.Step.Run {
    // The run step copies arguments before this temporary is freed.
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);

    // Use the compiler running this build for the nested build.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.addArg("--build-file");
    run.addFileArg2(b.path("consumer/build.zig"), .{ .make_absolute = true });
    run.addArg("consumer");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    run.addArg(b.fmt("-Druntime={}", .{runtime_loaded}));
    if (lua_root) |root| run.addArg(b.fmt("-Dlua-root={s}", .{root}));
    // Preserve an explicit CPU selection; it controls the float ABI and DynASM
    // backend (`build_support/abi.zig`).
    if (b.user_input_options.contains("cpu")) {
        run.addArg(b.fmt("-Dcpu={s}", .{
            target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM"),
        }));
    }
    run.addThirdPartyEnabledArgDarling(.{ .enabled = "-fdarling" });
    run.addThirdPartyEnabledArgDarling(.{ .enabled = "-Dconsumer-run-darling=true" });
    run.addThirdPartyEnabledArgQemu(.{ .enabled = "-fqemu" });
    run.addThirdPartyEnabledArgQemu(.{ .enabled = "-Dconsumer-run-qemu=true" });
    run.addThirdPartyEnabledArgRosetta(.{ .enabled = "-frosetta" });
    run.addThirdPartyEnabledArgRosetta(.{ .enabled = "-Dconsumer-run-rosetta=true" });
    run.addThirdPartyEnabledArgWasmtime(.{ .enabled = "-fwasmtime" });
    run.addThirdPartyEnabledArgWasmtime(.{ .enabled = "-Dconsumer-run-wasmtime=true" });
    run.addThirdPartyEnabledArgWine(.{ .enabled = "-fwine" });
    run.addThirdPartyEnabledArgWine(.{ .enabled = "-Dconsumer-run-wine=true" });
    // The nested build cannot inherit this build's job width.
    run.addArg("-j8");
    run.addArgs(&.{ "--summary", "all" });
    // Keep the nested graph's local cache separate from the parent.
    run.addArg("--cache-dir");
    run.addDirectoryArg2(
        std.Build.LazyPath.cache_root,
        .{
            .make_absolute = true,
            .suffix = b.fmt("{c}consumer", .{std.fs.path.sep}),
        },
    );
    // Keep relative environment paths anchored to the parent's working directory.
    inline for (.{ "ZIG_GLOBAL_CACHE_DIR", "ZIG_LIB_DIR" }) |name| {
        if (b.graph.environ_map.get(name)) |value| run.setEnvironmentVariable(name, value);
    }
    // Create the parent prefix before passing it as a directory input.
    run.step.dependOn(b.getInstallStep());
    run.addArg("--prefix");
    run.addDirectoryArg2(
        .{ .relative = .{ .base = .install_prefix } },
        .{ .make_absolute = true },
    );
    // Pass remaining caller arguments, including a runtime provider.
    run.addArg("--");
    run.addPassthruArgs();
    run.has_side_effects = true;
    return run;
}

/// Checks unsupported targets through LuaJIT's own preprocessor error.
/// New upstream support makes this expected-failure step fail.
fn addArchitectureRefusalCheck(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    triple: []const u8,
    err: abi.Unsupported,
) *std.Build.Step.Run {
    const message = switch (err) {
        error.Ppc64NotSupported => "No support for PPC64",
        error.ArchitectureNotSupported => abi.architecture_not_supported_message,
    };

    const run = b.addSystemCommand(&[_][]const u8{
        b.graph.zig_exe, "cc", "-E", "-x", "c",
    });
    run.setName(b.fmt("assert {s} is refused by lj_arch.h", .{triple}));
    if (!target.query.isNative()) {
        run.addArg("-target");
        run.addArg(triple);
    }
    run.addArg("-o");
    // Declare the preprocessor output without depending on it; a dependency
    // creates a graph cycle.
    _ = run.addOutputFileArg2(b.fmt("lj_arch-{s}.i", .{triple}), .{});
    run.addFileArg2(b.path("src/lj_arch.h"), .{});
    // lj_arch.h includes lua.h, which reaches luaconf.h from src/.
    run.addDirectoryArg2(b.path("src"), .{ .prefix = "-I" });
    // The expected upstream #error makes the target preprocessor exit 1.
    run.expectExitCode(1);
    run.expectStdErrMatch(message);
    return run;
}

/// Installs upstream's layout and this fork's required records.
fn addInstall(
    b: *std.Build,
    native: graph.Graph,
    selection: abi.Selection,
    target: std.Target,
    release_version: []const u8,
) void {
    // File install steps must be attached explicitly to the install step.
    const install = struct {
        fn file(builder: *std.Build, source: std.Build.LazyPath, dir: std.Build.InstallDir, dest: []const u8) void {
            builder.getInstallStep().dependOn(&builder.addInstallFileWithDir(source, dir, dest).step);
        }
    }.file;

    // Keep upstream's executable name, `luajit`.
    if (native.cli) |cli| install(b, cli.getEmittedBin(), .bin, "luajit");

    b.installArtifact(native.library);
    const headers = sources.public_headers_present(b.allocator) catch @panic("OOM");
    for (headers) |h| {
        native.library.installHeader(b.path(b.pathJoin(&.{ "src", h })), headerDest(b, h));
    }
    // `luajit.h` is generated by genversion.lua, not stored in src/.
    native.library.installHeader(native.version_header, headerDest(b, sources.version_generated_header));

    const present = sources.jit_modules_present(b.allocator) catch @panic("OOM");
    for (present) |m| {
        install(
            b,
            b.path(b.pathJoin(&.{ "src", "jit", m })),
            .{ .custom = "share" },
            b.pathJoin(&.{ "luajit-" ++ graph.mm_version, "jit", m }),
        );
    }
    install(
        b,
        native.vmdef_lua,
        .{ .custom = "share" },
        b.pathJoin(&.{ "luajit-" ++ graph.mm_version, "jit", "vmdef.lua" }),
    );

    install(b, b.path(sources.man_page), .{ .custom = "share" }, "man/man1/luajit.1");

    // Relocate pkg-config paths and add the external unwinder for static links.
    install(b, addPkgConfig(b, selection, target, release_version), .lib, "pkgconfig/luajit.pc");

    // Install upstream's unmodified COPYRIGHT text with the library.
    install(
        b,
        b.path("COPYRIGHT"),
        .{ .custom = "share" },
        b.pathJoin(&.{ "doc", "luajit-" ++ graph.mm_version, "COPYRIGHT" }),
    );

    // Install fork-owned licence and provenance records with the binary.
    const records = [_][]const u8{
        "NOTICE.md",
        "FORK-LICENSE.md",
        "UPSTREAM.md",
        "README.upstream.md",
    };
    for (records) |r| {
        install(
            b,
            b.path(r),
            .{ .custom = "share" },
            b.pathJoin(&.{ "licenses", "luajit", r }),
        );
    }
    install(
        b,
        b.path("README.md"),
        .{ .custom = "share" },
        b.pathJoin(&.{ "doc", "luajit-" ++ graph.mm_version, "README.md" }),
    );
}

fn headerDest(b: *std.Build, name: []const u8) []const u8 {
    return b.pathJoin(&.{ "luajit-" ++ graph.mm_version, name });
}

/// Matches the native graph's unwinder link set to keep pkg-config aligned.
fn needsExternalUnwinder(target: std.Target) bool {
    return switch (target.os.tag) {
        .linux, .hurd, .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };
}

/// Rewrites `etc/luajit.pc` for relocatable installs and the rolling version.
/// Drops Darwin's ELF-only flag and records the unwinder for static links.
fn addPkgConfig(
    b: *std.Build,
    selection: abi.Selection,
    target: std.Target,
    release_version: []const u8,
) std.Build.LazyPath {
    b.dependOnFileContents(b.path(sources.pkg_config_template));
    var root_dir = b.root.openDir(b.graph.io, ".", .{}) catch |err| std.debug.panic(
        "luajit: cannot open the build root: {s}",
        .{@errorName(err)},
    );
    defer root_dir.close(b.graph.io);
    const template = root_dir.readFileAlloc(
        b.graph.io,
        sources.pkg_config_template,
        b.allocator,
        .limited(1 << 16),
    ) catch |err| std.debug.panic(
        "luajit: cannot read the pkg-config template {s}: {s}",
        .{ sources.pkg_config_template, @errorName(err) },
    );

    // Keep upstream's prefix-relative module paths; this build installs no
    // files in those directories.
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, template, '\n');
    while (lines.next()) |line| {
        const rendered = if (std.mem.startsWith(u8, line, "prefix="))
            "prefix=${pcfiledir}/../.."
        else if (std.mem.startsWith(u8, line, "multilib="))
            "multilib=lib"
        else if (std.mem.startsWith(u8, line, "relver="))
            b.fmt("relver={s}", .{release_version})
        else if (std.mem.startsWith(u8, line, "includedir="))
            b.fmt("includedir=${{prefix}}/include/luajit-{s}", .{graph.mm_version})
        else if (selection.os == .osx and std.mem.indexOf(u8, line, "-Wl,-E") != null)
            std.mem.trim(u8, line, " ")
        else if (needsExternalUnwinder(target) and
            std.mem.startsWith(u8, line, "Libs.private:"))
            b.fmt("{s} -lgcc_s", .{std.mem.trim(u8, line, " ")})
        else
            line;
        out.appendSlice(b.allocator, rendered) catch @panic("OOM");
        out.append(b.allocator, '\n') catch @panic("OOM");
    }

    const files = b.addWriteFiles();
    return files.add("luajit.pc", out.items);
}

/// Compiles two C translation units against the installed headers and library.
/// Catches install-tree mismatches that in-tree module builds cannot see.
fn addHeaderCheck(b: *std.Build, linkage: std.lang.LinkMode, selection: abi.Selection) void {
    const check_step = b.step(
        "header-check",
        "Compile and link two C translation units against the installed headers " ++
            "and library, then run the result",
    );

    const include_dir: std.Build.LazyPath = .{
        .relative = .{
            .base = .install_prefix,
            .sub_path = b.fmt("include/luajit-{s}", .{graph.mm_version}),
        },
    };
    const lib_dir: std.Build.LazyPath = .{ .relative = .{ .base = .install_lib } };

    // Model the compiler invocation as a build step so install ordering is explicit.
    const mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .safe,
        .link_libc = true,
    });
    mod.addIncludePath(include_dir);
    mod.addLibraryPath(lib_dir);
    mod.linkSystemLibrary(graph.artifact_name, .{ .preferred_link_mode = linkage });
    mod.linkSystemLibrary("m", .{});
    switch (selection.os) {
        .linux, .other => mod.linkSystemLibrary("dl", .{}),
        else => {},
    }
    // Give the dynamic-link check executable a path to the installed library.
    if (linkage == .dynamic) mod.addRPath(lib_dir);

    mod.addCSourceFile(.{ .file = b.path("build_support/header_check_a.c") });
    mod.addCSourceFile(.{ .file = b.path("build_support/header_check_b.c") });

    const program = b.addExecutable(.{ .name = "luajit-header-check", .root_module = mod });
    // Compile only after the install tree has been written.
    program.step.dependOn(b.getInstallStep());

    const run = b.addRunArtifact(program);
    run.setName("run the installed-header C consumer");
    run.has_side_effects = true;
    check_step.dependOn(&run.step);
}
