// SPDX-License-Identifier: MIT
//! Zig 0.16 build for the LuaJIT package in this repository.
//!
//! Upstream pin: LuaJIT v2.1 rolling snapshot
//! `c6ffc141a8762b41703f9287d63d93622a13dd8f` (2026-09-08T08:43:01Z). The release
//! version is rolling: `Makefile:16-17` sets `MAJVER=2` and `MINVER=1`, and
//! `Makefile:22` derives `RELVER` from the commit timestamp, which this checkout
//! carries in `.relver` as `1788856981`. `build_support/graph.zig` reads that
//! value out of that file rather than repeating it, and says why the file is
//! where the version comes from.
//!
//! ## What this is
//!
//! LuaJIT is a just-in-time compiler for Lua 5.1, and it is not a C library with
//! a `configure` step. Building it needs:
//!
//!   * a **host toolchain**: `minilua`, upstream's minified Lua 5.1.5, which
//!     runs the two Lua generators;
//!   * **DynASM**, upstream's own assembler generator, turning
//!     `src/vm_<arch>.dasc` into `host/buildvm_arch.h`;
//!   * `buildvm`, which embeds that backend and writes the VM machine code and
//!     six generated definition files;
//!   * `genversion.lua`, which turns `src/luajit_rolling.h` into the public
//!     `luajit.h`.
//!
//! All four run on the **host** and emit code shaped for the **target**. Nothing
//! here runs a Makefile, a configure script, a build-time download, or git, and
//! nothing substitutes a stock Lua: the JIT, the FFI and the `jit.*` module set
//! are what this package delivers, and `zig build native-test` proves each of
//! them by running the delivered CLI.
//!
//! `build_support/graph.zig` owns the native graph -- the host toolchain, the
//! generators, the library, the CLI and the per-target ABI selection -- so the
//! published graph and each of the six cross-target checks are built by the same
//! code. `build_support/abi.zig` owns the architecture rules, each one citing
//! the `lj_arch.h` or `src/Makefile` line it reproduces. `build_support/sources.zig`
//! owns the translation-unit lists, each transcribed from an upstream
//! assignment.
//!
//! ## Steps
//!
//!   (default)        install the closure `make install` writes, and compile the
//!                    CLI against it
//!   test             run the facade tests for the selected target
//!   smoke            run the smoke example
//!   consumer         build the separate `consumer/` package for the selected
//!                    target, and run it when this host can execute that target
//!   native-test      run the delivered `luajit` CLI and check that it is a JIT
//!   header-check     compile and link two C translation units against the
//!                    *installed* headers and library, then run them
//!   check            compile the native graph, the facade, the tests and the
//!                    smoke example for the six required cross targets,
//!                    running nothing. The consumer is not in this matrix: it
//!                    is its own package, so `check -Dtarget=<triple>` does not
//!                    reach it and `zig build consumer -Dtarget=<triple>` does
//!
//! `test` gives the test binary a Run step for whatever `-Dtarget` names,
//! including a foreign target, so the driver decides what executes it: a host
//! target runs, a foreign target runs under whatever executor the driver has, and
//! one with no executor is reported as build-only coverage rather than as a
//! pass. `cross-test.profile.sh` is this package's half of that arrangement.
//!
//! A 32-bit `-Dtarget` makes one of those generators 32-bit as well: `buildvm`
//! refuses to run unless `sizeof(void*)` matches the target's `LJ_32`/`LJ_64`
//! (`src/host/buildvm.c:449-453`), which is what upstream answers with
//! `HOST_CC="gcc -m32"` (`src/Makefile:32`, `:187-188`), and what
//! `build_support/graph.zig`'s `generatorHostTarget` selects here. So it
//! executes under the same rule as the test binary: a build machine whose
//! kernel already runs 32-bit programs needs nothing extra, and otherwise the
//! driver supplies the executor, exactly as it does for the test binary.
//!
//! ## Options
//!
//!   -Dtarget=<triple>   build for one target; `check` then covers that one
//!                       target instead of all six
//!   -Doptimize=<mode>   standard; passed to every graph below
//!   -Dcpu=<model>       standard; only meaningful together with `-Dtarget`
//!   -Dlinkage=static|dynamic
//!                       which kind of library to build. **The default is
//!                       `static`**, matching every existing package in this
//!                       workspace except PCRE2 and no exception. Upstream's
//!                       default is `mixed` (`src/Makefile:73`), which is a
//!                       superset of static; a package that installs one
//!                       artifact has to choose, and static is the choice that
//!                       needs no runtime search path.
//!   -Dlua-root=<path>
//!                       the absolute install root to compile into the binary as
//!                       `LUA_ROOT` and `LUA_LJDIR` (`src/Makefile:290-304`). It
//!                       reaches no installed file: `luajit.pc` keeps
//!                       `prefix=${pcfiledir}/../..` and its module directories
//!                       are left as the template's own `${prefix}` references,
//!                       so the installed file is relocatable and names no build
//!                       machine's path.
//!                       Defaults to `--prefix` when it is absolute **and
//!                       outside the build cache**, and to *no* definition
//!                       otherwise: a dependency child is never given a
//!                       `--prefix`, and the digest directory the build system
//!                       writes in its place (`std/Build.zig:721-723`) is a path
//!                       the cache manager may delete. Undefined is upstream's own
//!                       documented distribution layout, where `luaconf.h:37`
//!                       supplies `/usr/local`; `doc/install.html#distro` is
//!                       upstream's instruction to pass `PREFIX` rather than
//!                       patch `luaconf.h`.
//!
//! ## No system-library mode
//!
//! There is deliberately no `b.systemIntegrationOption`. LuaJIT's published
//! surface here is not just a library: it is the CLI, the `jit.*` module set, the
//! generated `jit/vmdef.lua`, the rolling version symbol, and a VM whose bytecode
//! tables were generated from *these* sources. An installed `libluajit-5.1` binds
//! to its own `jit/vmdef.lua`, its own `jit.bc` and its own `luajit.h`; pointing a
//! translation at this repository's headers while linking that library is the
//! "bundled header newer than the installed ABI" failure this workspace forbids.
//! The rule is recorded as NOT APPLICABLE for this wave rather than claimed as
//! satisfied.
//!
//! ## Installed closure
//!
//! `zig build install` writes, under `--prefix`:
//!
//!   bin/luajit                        the CLI
//!   lib/libluajit-5.1.a                `-Dlinkage=static`
//!   lib/libluajit-5.1.so.2.1.<relver>  `-Dlinkage=dynamic`, with the `.so.2`
//!   lib/libluajit-5.1.so               and `.so` symlinks, and a `.pc` below
//!   include/luajit-2.1/{lua,luaconf,lualib,lauxlib,lua.hpp,luajit}.h
//!   share/luajit-2.1/jit/*.lua         the eighteen checked-in modules plus the
//!                                      generated `vmdef.lua`
//!   share/man/man1/luajit.1
//!   lib/pkgconfig/luajit.pc
//!   share/doc/luajit-2.1/COPYRIGHT    upstream's licence text, byte-identical
//!   share/doc/luajit-2.1/README.md     this fork's README
//!   share/licenses/luajit/{NOTICE,FORK-LICENSE,UPSTREAM}.md
//!   share/licenses/luajit/README.upstream.md
//!
//! The last five are this fork's records rather than upstream's. They are
//! installed by this graph rather than by a packaging wrapper, so there is one
//! writer per path: a consumer cannot receive the binary without the records
//! that say what it is and under what terms, and `package.nix` is a wrapper that
//! invokes `zig build install` and adds nothing of its own.
//!
//! Those names are upstream's own (`Makefile:56-71`, `:98-104`, `:133-146`).
//! Two differences from `make install` are deliberate and are not silent:
//! upstream also installs the versioned alias `bin/luajit-2.1.<relver>` as a
//! symlink to `bin/luajit`, which Zig's install step cannot create; and
//! upstream's `INSTALL_LMODD`/`INSTALL_CMODD` (`Makefile:47-50`, `:75`) are two
//! empty directories for Lua and C modules that are created but never filled,
//! and this build does not create empty directories.
//!
//! Upstream's Windows names differ from what a Zig `addLibrary` emits: upstream
//! writes `lua51.dll` with a `libluajit-5.1.dll.a` import library
//! (`Makefile:220`, `:60`), while Zig writes `luajit-5.1.dll` and
//! `luajit-5.1.lib` from the same artifact name that produces
//! `libluajit-5.1.a` and `libluajit-5.1.so*` everywhere else. That is a naming
//! difference in the delivered file, not an ABI one: the exported symbols and the
//! `-lluajit-5.1` link name are the same on every platform.
//!
//! ## What `check` covers
//!
//! Six targets: `x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos-none`,
//! `x86_64-windows-gnu`, `riscv64-linux-gnu` and `wasm32-wasi`. Two of them --
//! riscv64 and wasm32 -- are **not architectures LuaJIT 2.1 supports**: the
//! chain at `lj_arch.h:54-70` names x86, x64, ARM, arm64, PPC, MIPS and MIPS64,
//! and its `#else` is `lj_arch.h:69`, `#error "Architecture not supported (in this
//! version), see: https://luajit.org/status.html#architectures"`. `check` does
//! not drop them and does not pretend to compile them: `build.zig` turns each
//! into a step that runs the target's own preprocessor over `src/lj_arch.h` and
//! *requires* upstream's refusal. A step that passes has therefore observed the
//! boundary rather than asserted it, and the day a LuaJIT release adds RISC-V
//! the step fails and says so.
//!
//! The matrix compiles the library, the CLI, the facade, `tests.zig` and
//! `smoke.zig`. It does not compile `consumer/src/main.zig`: that file belongs
//! to a package with its own manifest, and building it here would reach it
//! through this package's module instead of through `b.dependency`, which is
//! the only route the consumer exists to prove. `zig build consumer
//! -Dtarget=<triple>` builds it the way a dependent would.
//!
//! `-Dcpu=baseline` is accepted, as it is everywhere in this workspace: the CPU
//! model is a `Target.Query` field, so naming a baseline is a target query, not a
//! separate switch. LuaJIT's `VM` generation reads no CPU feature that would
//! change its output, so the baseline model does not alter what is built.

const std = @import("std");

const graph = @import("build_support/graph.zig");
const sources = @import("build_support/sources.zig");
const abi = @import("build_support/abi.zig");

/// The six targets `check` covers when no `-Dtarget` is named. The order is the
/// one this workspace uses everywhere; nothing is skipped and nothing here is
/// pre-judged.
const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

/// Whether the caller named a target on the command line.
///
/// `standardTargetOptions` cannot answer this: it folds `-Dtarget=X` and "no
/// `-Dtarget` at all" into the same resolved value, so comparing the query
/// against the host would report a host-native cross target as "not selected"
/// and check all six when the caller asked for one. The raw option table can,
/// because `standardTargetOptionsQueryOnly` registers the `target` option by
/// exactly this name and every `-Dname=value` the user passed is a key in it.
fn target_was_named(b: *const std.Build) bool {
    return b.user_input_options.contains("target");
}

/// The install root to compile into the library, or null when there is none.
///
/// `b.install_prefix` answers a different question from "did the caller name a
/// prefix", and the difference matters here. A `b.dependency` child never
/// receives one: `createChildOnly` overwrites the prefix with a digest
/// directory inside the build cache (`std/Build.zig:721-723`), so the resolved
/// value is `<cache>/i/<hash>` and it is absolute. Compiling that into
/// `LUA_ROOT`, into the delivered CLI's package path and into `luajit.pc` would
/// name a directory the cache manager may discard, and the dependency route is
/// exactly what `consumer/` exists to prove.
///
/// `--prefix` cannot be asked about directly the way `target_was_named` asks
/// about `-Dtarget`: the build runner parses it itself
/// (`lib/compiler/build_runner.zig:165-166`) and hands it to
/// `resolveInstallPrefix`, so unlike `-Dtarget` it never reaches
/// `b.user_input_options`. What the two cases share is the location. A prefix
/// inside the build cache is the digest directory `createChildOnly` writes; a
/// prefix outside it is a real directory, whether it is the `--prefix` a caller
/// named or the `<build_root>/zig-out` default (`std/Build.zig:732-733`).
fn install_root(b: *const std.Build) ?[]const u8 {
    const prefix = b.install_prefix;
    if (!std.fs.path.isAbsolute(prefix)) return null;
    var cache = b.cache_root.path orelse return prefix;
    while (cache.len > 1 and std.fs.path.isSep(cache[cache.len - 1])) {
        cache = cache[0 .. cache.len - 1];
    }
    if (prefix.len > cache.len and std.mem.startsWith(u8, prefix, cache) and
        std.fs.path.isSep(prefix[cache.len]))
    {
        return null;
    }
    return prefix;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The default is static. Every other package in this workspace keeps its own
    // existing linkage default, and upstream's `mixed` (`src/Makefile:73`) is not
    // expressible as "one installed artifact".
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Build libluajit-5.1 as a static archive (the default) or a shared library. " ++
            "This selects the kind of artifact `zig build install` writes and, on " ++
            "Windows, whether -DLUA_BUILD_AS_DLL applies (src/Makefile:559-575).",
    ) orelse .static;

    // Whether the facade's native calls are resolved through the platform
    // loader at run time instead of being linked to the archive. Orthogonal to
    // `-Dlinkage`: that chooses the kind of artifact installed, this chooses
    // where the facade's calls go. The library is built and installed either
    // way -- it is what a runtime build loads.
    //
    // The default is false, so the ordinary build links. In that mode the
    // facade's `c` import is the translated header and `rt` is the loader core
    // that supplies `LoadSource` and `LoadError`; in the runtime mode `c` is a
    // generated dispatch that carries the same declarations and resolves the
    // calls at run time. `runtime/graph.zig` owns the dispatch and the
    // substitution; `zig/root.zig:213` tells the two apart with
    // `@hasDecl(c, "rt_runtime_loaded")`, so one facade source covers both.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native symbols through the platform loader at run time " ++
            "instead of linking libluajit-5.1 into the facade. Requires the " ++
            "driver-owned runtime/{loader.zig,sync.c,sync.h,generate.zig}.",
    ) orelse false;

    // The install root compiled into the binary and written into `luajit.pc`.
    // Absolute or nothing: `LUA_PATH_DEFAULT` is a runtime search path, so a
    // relative one would be resolved against the process's working directory.
    const lua_root_option = b.option(
        []const u8,
        "lua-root",
        "Absolute install root compiled into the binary as LUA_ROOT and LUA_LJDIR " ++
            "(src/Makefile:290-304). Defaults to --prefix when that is an absolute " ++
            "path outside the build cache; left undefined otherwise, which is " ++
            "upstream's documented distribution layout (doc/install.html#distro). " ++
            "It is deliberately not written into luajit.pc: that file names its " ++
            "own location instead, so it still resolves after the tree is copied. " ++
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
    const lua_root = lua_root_option orelse install_root(b);

    // Whether this target is one LuaJIT 2.1 supports at all.
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

    // One read of the tracked `.relver`, shared by every consumer below: the
    // generated `luajit.h`, the `relver=` line of `luajit.pc` and a shared
    // library's version. `graph.releaseVersion` says where the digits come from
    // and why that is the only place they come from.
    const release_version = graph.releaseVersion(b);

    const native = graph.addGraph(b, .{
        .target = target,
        .optimize = optimize,
        .public = true,
        .name_prefix = graph.artifact_name,
        .linkage = linkage,
        .release_version = release_version,
        .with_cli = true,
        // `bin/luajit` is installed *and* executed by `native-test`, and one
        // binary cannot carry both search paths, so ask for the second copy of
        // the CLI. `graph.addGraph` decides whether the two really differ;
        // under `-Dlinkage=static`, on Windows and under `-Druntime=true` they
        // do not, and nothing is compiled twice. The facade needs no such
        // flag: no installed program is built from it.
        .for_cache_runs = true,
        .lua_root = lua_root,
        .runtime_loaded = runtime_loaded,
    }) catch unreachable;

    addInstall(b, native, selection, target.result, release_version);

    // --- the native gate the driver can run without the facade -------------
    // The CLI `native-test` drives is the same program `zig build install`
    // writes, from the same sources and the same options, built against the
    // build cache's search path instead of the install tree's: `bin/luajit`
    // carries only `$ORIGIN/../lib`, and out of the build cache there is no
    // `lib/` beside it. The script is passed as a file argument, so its
    // content is part of the run's inputs.
    const run_selfcheck = b.addRunArtifact(native.run_cli.?);
    run_selfcheck.setName("luajit native self-check");
    run_selfcheck.addFileArg(b.path("build_support/native_selfcheck.lua"));
    // A run whose inputs did not change is otherwise served from the run cache
    // and never executes, which would let a second `zig build native-test`
    // report success without observing anything.
    run_selfcheck.has_side_effects = true;

    // The self-check requires the `jit.*` modules, and the CLI finds them
    // through `LUA_JPATH`, which is `LUA_LJDIR "/?.lua"` inside
    // `LUA_PATH_DEFAULT` (`luaconf.h:56`, `:63`) with `LUA_LJDIR` compiled in
    // as `<install root>/share/luajit-2.1` (`graph.zig:903-906`,
    // `src/Makefile:297`). Those files are written by the install step and by
    // nothing else, so without this dependency `native-test` runs against
    // whatever the prefix happens to hold: nothing at all the first time a
    // prefix is used, and a stale tree every time after. `addHeaderCheck`
    // already depends on the install step for the same reason, and says so.
    run_selfcheck.step.dependOn(b.getInstallStep());
    b.step(
        "native-test",
        "Run the delivered luajit CLI and check the JIT, the FFI and the jit modules",
    ).dependOn(&run_selfcheck.step);

    addHeaderCheck(b, linkage, selection);

    // --- the Zig-facing steps ---------------------------------------------
    // `zig build` also compiles the CLI, so the installed closure and the binary
    // that uses it are built by the same invocation. It is a compile, not a run:
    // executing it belongs to `native-test`.
    b.getInstallStep().dependOn(&native.cli.?.step);

    const facade_tests = b.addTest(.{
        .name = "luajit-tests",
        .root_module = facadeProgram(b, target, optimize, native.module.?, "tests.zig"),
    });
    // A test binary is never installed, and the published module already
    // carries the build cache's entry, so it needs no facade of its own.
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

    // The consumer is a package in its own right, with its own manifest and its
    // own `zig build run`. Compiling its source here instead would prove only
    // that a source file inside this package compiles, which every in-tree gate
    // already covers; what has to be shown is that a package which did not
    // write the module resolves it by name. So the step below runs that package.
    b.step("consumer", "Build the separate consumer/ package for the selected " ++
        "target, and run it when this host can execute it").dependOn(&runConsumer(b, target, optimize, linkage, runtime_loaded, lua_root).step);

    // --- the cross-target gate ---------------------------------------------
    // The consumer is not in this matrix: it is its own `zig build`, run from
    // inside `consumer/`, and it is compiled for whichever target the command
    // line names above. `zig build consumer -Dtarget=<triple>` is how a
    // cross target reaches it.
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

/// A Zig program or test root that imports the published facade module.
///
/// `link_libc` is stated on every one of them even though the facade carries it:
/// a dependent states its own, and this build should fail here if the facade ever
/// stopped bringing libc along.
fn facadeProgram(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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

/// Compile the graph, the facade and the Zig roots for one cross target and
/// attach them to `step`. Nothing runs: a cross-compiled binary cannot run on
/// the host, and a result reported from such a compile would be a claim about
/// execution that did not happen.
fn addTargetCheck(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    lua_root: ?[]const u8,
    runtime_loaded: bool,
    release_version: []const u8,
) void {
    const resolved = b.resolveTargetQuery(query);
    const triple = resolved.result.zigTriple(b.allocator) catch @panic("luajit: unspellable target");

    // An architecture upstream does not support is not skipped and not faked: the
    // step below runs the target's own preprocessor over `src/lj_arch.h` and
    // requires upstream's `#error` at `lj_arch.h:69`. Passing means the boundary
    // was observed on that exact target with that exact compiler.
    _ = abi.select(resolved.result) catch |err| switch (err) {
        error.Ppc64NotSupported, error.ArchitectureNotSupported => {
            step.dependOn(&addArchitectureRefusalCheck(b, resolved, triple, err).step);
            return;
        },
    };

    const native = graph.addGraph(b, .{
        .target = resolved,
        .optimize = optimize,
        // Private: modules are registered by name against the whole build, so
        // registering `luajit` once per check target would leave only the last
        // reachable and silently stop checking the rest.
        .public = false,
        .name_prefix = b.fmt("luajit-{s}", .{triple}),
        .linkage = linkage,
        .release_version = release_version,
        // The CLI is compiled, not run: it is part of the delivered closure, and a
        // foreign one cannot be executed here anyway.
        .with_cli = true,
        .lua_root = lua_root,
        // The same configuration the published graph uses, so `check` never
        // covers a shape the default build does not produce.
        .runtime_loaded = runtime_loaded,
    }) catch unreachable;

    step.dependOn(&native.library.step);
    step.dependOn(&native.cli.?.step);
    step.dependOn(&b.addTest(.{
        .name = b.fmt("luajit-tests-{s}", .{triple}),
        .root_module = facadeProgram(b, resolved, optimize, native.module.?, "tests.zig"),
    }).step);
    step.dependOn(&b.addExecutable(.{
        .name = b.fmt("luajit-smoke-{s}", .{triple}),
        .root_module = facadeProgram(b, resolved, optimize, native.module.?, "smoke.zig"),
    }).step);
    // The consumer is deliberately absent from this list. It is a separate
    // package reached through `b.dependency`, so compiling its source here
    // would build it the way every other in-tree root is built and would
    // prove nothing about the route that matters. `zig build consumer
    // -Dtarget=<triple>` compiles it through its own manifest instead.
}

/// Runs the consumer package as its own `zig build` in `consumer/`.
///
/// The consumer is a separate package on purpose: a manifest dependency here
/// would close a cycle, because its manifest points back at this package by
/// path. Running it as a separate build is what makes the proof real - that a
/// package which writes only `b.dependency("luajit", ...)` and
/// `dep.module("luajit")` gets a working, correctly linked library, with the
/// archive and libc arriving through the module and nothing else.
///
/// The delivery and dispatch options reach the nested build by name, so
/// `zig build consumer -Dlinkage=dynamic` checks the shared object and
/// `-Druntime=true` checks the loaded one rather than both silently exercising
/// the default archive. `-Druntime=false` is passed explicitly rather than
/// omitted: the nested build has the same default, but a nested build that
/// guessed would be a different library from the one under test.
///
/// Run, or only install. `hostCanExecute` asks the question `Step.Run` will ask
/// about the nested consumer's binary, so the nested build gets `run` when this
/// host can execute the selected target and `install` when it cannot. The query
/// cannot answer that: `Query.isNative` is true only when every field is null,
/// so `-Dtarget=x86_64-linux-gnu` was never native on an x86_64 Linux host.
///
/// `-Dlua-root` is forwarded, and only when there is one. `consumer/build.zig`
/// declares the option and hands it to its own `b.dependency("luajit", ...)`
/// unchanged, which is what makes that legal: the build runner rejects an
/// option no build script reads (`std/Build.zig:1644-1655`, reached from
/// `build_runner.zig:487`), so an option the consumer did not declare would
/// fail the nested build rather than configure it. What travels is the
/// *resolved* root -- `lua_root_option orelse install_root(b)`, `build.zig:295`
/// -- and not the text the caller typed, so the library the consumer links is
/// the one this build installed rather than one that resolved the same question
/// again and might answer it differently. A build with no resolved root passes
/// nothing and leaves the library's own policy in force.
///
/// `--prefix` itself does not reach the library, and cannot: the library reaches
/// this proof as `consumer`'s `b.dependency` child, and `createChildOnly`
/// replaces that child's install prefix with a cache digest directory whatever
/// the nested build was told (`std/Build.zig:721-723`). It does travel to the
/// nested build itself, so the consumer package installs where the caller
/// asked; what carries the root past that is the option above.
///
/// The target travels down as the caller's *query*, never as this graph's
/// resolved target. `Target.Query.zigTriple` spells arch, OS, versions and ABI
/// and writes `native` for a query that names nothing
/// (`lib/std/Target/Query.zig:421-423`), which is the same source `std.Build`
/// itself uses to hand a `ResolvedTarget` to a dependency
/// (`lib/std/Build.zig:451-462`) -- so both graphs resolve from the same
/// question, and a nested build told `native` compiles against this machine.
///
/// `target.result.zigTriple` spells the *resolved* target, whose host CPU
/// carries a feature range -- `x86_64-linux.6.12...6.12-gnu.2.42` here -- and
/// a triple has no field for a dynamic linker at all. The nested build would
/// then read an explicitly named target, resolve it against the ABI's defaults
/// rather than against this machine, and ask for `/lib64/ld-linux-x86-64.so.2`
/// where the host's real linker is the Nix store path. Its `run` refuses that,
/// and is right to: `Step.Run` compares `b.graph.host.result.dynamic_linker`
/// with the target's own (`lib/std/Build/Step/Run.zig:1339-1343`). The same
/// architecture, the same OS and the same libc version are not a native
/// selection, and the query is what stops them from pretending to be one.
///
/// The dynamic linker rides the native route rather than travelling as an
/// argument. A query that names nothing *is* `b.graph.host`
/// (`lib/std/Build.zig:2704-2707`), so this graph and the nested one both
/// compile against the linker the machine actually has. No argument carries it
/// because `b.dependency` carries none either: a `-Ddynamic-linker` forwarded
/// to the nested build alone would give its consumer executable a linker that
/// its own library half never received.
///
/// The CPU is forwarded for the same reason -- the nested build has to be told
/// what the parent was told -- and for the reason below.
///
/// Both cache directories travel, and they are not the same directory. The
/// local one gets the `consumer` subdirectory because two build graphs must not
/// write the same manifest directory. The global one is forwarded exactly as
/// the runner resolved it, because that cache is keyed by content and shared by
/// contract -- `lib/std/Build.zig:122` holds it on the graph,
/// `build_runner.zig:73-76` fills `path` unconditionally and `:89` assigns it,
/// and `lib/std/Build/Step/Compile.zig:1478-1479` is the compiler's own
/// two-token emit. A nested build left to resolve its own would look outside
/// the approved root for a selection this build was given. `Directory.path` is
/// optional (`lib/std/Build/Cache/Directory.zig:13`) and this runner never
/// leaves it null, so the guard is the type's and no fallback string is
/// substituted.
///
/// The install prefix travels too, when the caller named one. A nested build
/// with no `--prefix` resolves `consumer/zig-out`, a build artefact inside a
/// source package; a relative value would resolve against that `consumer/`
/// working directory rather than this build's root, so it is made absolute
/// first. A caller who named none is left alone: the nested build then resolves
/// the same `zig-out` this graph would.
///
/// The job width and the summary travel with it. `--summary` is two tokens
/// because that is how the build runner spells it
/// (`build_runner.zig:262-265`), and `-j8` because the width a nested build
/// derives is neither the one this build was asked for nor the same one on the
/// next machine.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    lua_root: ?[]const u8,
) *std.Build.Step.Run {
    // `addArg` copies each argument, so this temporary outlives nothing.
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);

    // `b.graph.zig_exe` is the compiler running this build script, so the nested
    // build is the same toolchain rather than whatever is on PATH.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    run.addArg(b.fmt("-Druntime={}", .{runtime_loaded}));
    // Set or absent, never empty and never defaulted here: see the note above.
    if (lua_root) |root| run.addArg(b.fmt("-Dlua-root={s}", .{root}));
    // `-Dtarget=` above carries architecture, OS and ABI, and
    // `Target.Query.zigTriple` says nothing at all about the CPU: an ARM target
    // comes out as `arm-linux-musleabi`, which does not say whether the core has
    // VFP or which PCS it uses. `build_support/abi.zig:177-186` derives
    // `LJ_ARCH_HASFPU` and the soft-float ABI from exactly those features, and
    // the DynASM FPU/HFABI selection follows from them, so a nested build
    // without `-Dcpu` configures a different VM than the one it is testing.
    //
    // Forwarded when the caller named one, and passed over when they did not.
    // `b.user_input_options` records exactly what was on the command line --
    // `build_runner.zig:154` for `-Dname=value` and `:157` for `-Dname` -- so
    // `contains("cpu")` is true for `-Dcpu=`, and is not made true by a
    // `-Dtarget` that implies a model. That is the whole of the condition, and
    // the two graphs still agree when it does not fire: with nothing named both
    // resolve `b.graph.host` (`std/Build.zig:2704-2707`) and read this machine's
    // real CPU, and with a bare `-Dtarget` both take the cross query's
    // `baseline` model (`lib/std/Target/Query.zig:497-502`). Only an explicitly
    // named model has to travel, because only then can this graph hold one the
    // nested build would not derive.
    //
    // Forwarded as the query re-serialized rather than as the text they typed,
    // because `std.Build` keeps the typed text in a private type this file
    // cannot read and the query is what every later decision is resolved from
    // anyway.
    if (b.user_input_options.contains("cpu")) {
        run.addArg(b.fmt("-Dcpu={s}", .{
            target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM"),
        }));
    }
    // Forward the selected executor and its dynamic-linker support.
    if (b.enable_darling) run.addArg("-fdarling");
    if (b.enable_qemu) run.addArg("-fqemu");
    if (b.enable_rosetta) run.addArg("-frosetta");
    if (b.enable_wasmtime) run.addArg("-fwasmtime");
    if (b.enable_wine) run.addArg("-fwine");
    if (b.libc_runtimes_dir) |runtimes| run.addArgs(&.{ "--libc-runtimes", runtimes });
    // The nested build carries this workspace's job count in its own command
    // line: nothing can append a `-j` to a `Run` step's command, so a nested
    // build left to derive its own width takes `cpu_count - 1`
    // (`lib/std/Io/Threaded.zig:1639`), and the consumer this step proves then
    // compiles at a different width from the build that asked for it -- and at
    // a different width again on whichever machine runs the gate.
    run.addArg("-j8");
    // The same summary the outer entry asked for, two tokens because that is
    // the runner's spelling (`build_runner.zig:262-265`).
    run.addArgs(&.{ "--summary", "all" });
    // Two arguments, not one `--cache-dir=...`: the second is the form the build
    // system emits to the compiler itself. Two build graphs must not write the
    // same manifest directory, so the nested one gets a subdirectory.
    if (b.cache_root.path) |cache| {
        run.addArg("--cache-dir");
        run.addArg(b.fmt("{s}/consumer", .{cache}));
    }
    // The global cache travels as the runner resolved it, with no subdirectory:
    // it is keyed by content and meant to be shared, so a suffix would name a
    // directory no other build in this workspace uses. Two tokens again --
    // `--global-cache-dir [path]`, `build_runner.zig:1675` -- and the compiler
    // emits it the same way (`lib/std/Build/Step/Compile.zig:1478-1479`).
    if (b.graph.global_cache_root.path) |global| {
        run.addArg("--global-cache-dir");
        run.addArg(global);
    }
    // The install prefix this invocation resolved, handed on when the caller
    // named one. A nested `zig build` left to resolve its own installs into
    // `consumer/zig-out` - a build artefact inside a source package - rather
    // than into the directory the caller asked for. A relative `--prefix`
    // would resolve against the working directory set above, `consumer/`,
    // and not against this build's root, so it is made absolute before it is
    // handed on. `DESTDIR` needs no forwarding, because the nested build
    // inherits the environment this one ran with.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        const prefix = if (std.fs.path.isAbsolute(b.install_prefix))
            b.install_prefix
        else
            b.pathJoin(&.{ b.graph.cache.cwd, b.install_prefix });
        run.addArg("--prefix");
        run.addArg(prefix);
    }
    // The caller's own arguments, last and behind `--`, so a runtime-loading
    // consumer can be told which provider to load:
    // `zig build consumer -Druntime=true -- --provider <path>`.
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    // The nested build is this step's only observable effect.
    run.has_side_effects = true;
    return run;
}

/// True when this build can execute `target`'s binaries.
///
/// That is `std.zig.system.getExternalExecutor`, the question `Step.Run` asks
/// about the artifact it is about to spawn, with the build runner's own executor
/// switches in `allow_*` and the consumer's libc requirement in `link_libc`.
/// `.qemu` is gated apart: `Run` fails a cross GNU-libc target that has no
/// runtimes directory rather than skipping it, so this installs rather than runs.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .allow_darling = b.enable_darling,
        .allow_qemu = b.enable_qemu,
        .allow_wasmtime = b.enable_wasmtime,
        .allow_wine = b.enable_wine,
        // The consumer links libc through the library module it imports, which
        // is the fact `Run`'s `need_cross_libc` and `.link_libc` are told here.
        .qemu_fixes_dl = candidate.isGnuLibC() and b.libc_runtimes_dir != null,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, host, candidate, options)) {
        .native, .rosetta => true,
        // Reachable only for an executor the switches above enabled.
        .wine, .wasmtime, .darling => true,
        // Not a yes on its own: `Run` fails a cross GNU-libc target with no
        // runtimes directory rather than skipping the run.
        .qemu => !(candidate.isGnuLibC() and b.libc_runtimes_dir == null),
        // No dynamic linker to load, or no enabled executor for this target.
        .bad_dl, .bad_os_or_cpu => false,
    };
}

/// A step that requires upstream's own architecture refusal for one target.
///
/// `src/lj_arch.h:69` is `#error "Architecture not supported (in this version),
/// see: https://luajit.org/status.html#architectures"`, reached when the chain at
/// `lj_arch.h:54-70` matches no branch. This preprocessor is
/// `b.graph.zig_exe cc`, the compiler that also compiles the C core, run for the
/// target in question.
///
/// The step succeeds only when the compiler *refuses*, which is the observed
/// boundary. The day a LuaJIT release supports the architecture, the compile
/// succeeds, `expectExitCode(1)` fails, and the gate says why -- rather than a
/// target being quietly dropped from the matrix.
fn addArchitectureRefusalCheck(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    triple: []const u8,
    err: abi.Unsupported,
) *std.Build.Step.Run {
    const message = switch (err) {
        // `lj_arch.h:369-370`: `#error "No support for PPC64"`.
        error.Ppc64NotSupported => "No support for PPC64",
        // `lj_arch.h:69`.
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
    // Named rather than discarded, and deliberately not made a dependency
    // of anything. `-E` writes the expanded header to this cache path, so
    // the run's output is declared in the graph. `addOutputFileArg` returns
    // a path owned by this very `Run` step, so
    // `addStepDependencies(&run.step)` on it is the step depending on the
    // artifact it produces: `std.Module.Graph`'s topological sort never
    // clears that node's dependencies and reports
    // `dependency loop detected: assert <triple> is refused by lj_arch.h`,
    // which is what made `check` die before any cell ran. Nothing consumes
    // the file; what this step observes is the refusal itself, on stderr.
    _ = run.addOutputFileArg(b.fmt("lj_arch-{s}.i", .{triple}));
    run.addFileArg(b.path("src/lj_arch.h"));
    // `src/lj_arch.h:9` includes `lua.h`, which reaches `luaconf.h` and
    // `<stddef.h>` (`lua.h:13`, `:16`; `luaconf.h:12`), so `src/` is on the line.
    run.addPrefixedDirectoryArg("-I", b.path("src"));
    // Clang exits 1 on a preprocessing error, and the message it prints is the
    // text inside the `#error` without the surrounding quotes.
    run.expectExitCode(1);
    run.expectStdErrMatch(message);
    return run;
}

/// The installed closure, laid out the way upstream's `install` target writes it.
///
/// `Makefile:130-148` is the rule this reproduces. Every destination below is
/// upstream's own: `INSTALL_TSYMNAME` (`Makefile:55`) for the CLI,
/// `INSTALL_ANAME`/`INSTALL_SONAME` (`Makefile:56-59`) for the library,
/// `INSTALL_DEFINC` (`Makefile:42`) for the headers, `INSTALL_JITLIB`
/// (`Makefile:46`) for the Lua modules, `INSTALL_MAN` (`Makefile:51`) for the man
/// page and `INSTALL_PC` (`Makefile:52`) for the pkg-config file.
fn addInstall(
    b: *std.Build,
    native: graph.Graph,
    selection: abi.Selection,
    target: std.Target,
    release_version: []const u8,
) void {
    // `addInstallFileWithDir` creates the step and returns it; it does not
    // attach it to the install step (`std/Build.zig:1717-1723`), and
    // `installFile` is the wrapper that does the attaching
    // (`std/Build.zig:1675-1677`). Every call below therefore goes through
    // `install`, which binds the returned step explicitly, rather than
    // discarding the return value -- an unbound install step is never built,
    // and the file silently never lands in the prefix.
    // The parameter is named `builder`, not `b`: the enclosing function already
    // binds `b`, and Zig rejects a nested declaration that shadows it.
    const install = struct {
        fn file(builder: *std.Build, source: std.Build.LazyPath, dir: std.Build.InstallDir, dest: []const u8) void {
            builder.getInstallStep().dependOn(&builder.addInstallFileWithDir(source, dir, dest).step);
        }
    }.file;

    // The CLI. `installArtifact` would name it after the artifact; the installed
    // name is upstream's `INSTALL_TSYMNAME` (`Makefile:55`).
    if (native.cli) |cli| install(b, cli.getEmittedBin(), .bin, "luajit");

    // The library, with its headers travelling beside it so a dependent needs
    // only `dep.artifact("luajit-5.1")`. `installArtifact` attaches itself.
    b.installArtifact(native.library);
    const headers = sources.public_headers_present(b.allocator) catch @panic("OOM");
    for (headers) |h| {
        native.library.installHeader(b.path(b.pathJoin(&.{ "src", h })), headerDest(b, h));
    }
    // `luajit.h` is generated, not a tree file: `src/.gitignore:2` lists it and
    // `src/Makefile:670-673` produces it.
    native.library.installHeader(native.version_header, headerDest(b, sources.version_generated_header));

    // The `jit` module set: the eighteen checked-in modules plus the generated
    // `vmdef.lua`, all under `share/luajit-2.1/jit` (`Makefile:46`, `:99-104`).
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

    // `Makefile:141`.
    install(b, b.path(sources.man_page), .{ .custom = "share" }, "man/man1/luajit.1");

    // `Makefile:143-144`, with `SED_PC` (`Makefile:86-91`) applied: `multilib=`
    // and `relver=` are rewritten, `prefix=` and `includedir=` are re-derived
    // from the installed file's own location, and on Darwin the `-Wl,-E` in
    // `Libs.private` is dropped because that flag is ELF-only. The template is
    // read and rewritten here rather than copied, so the installed file names
    // the root this build actually installed into. `Libs.private` also gains the
    // external unwinder this target's archive needs; see `addPkgConfig`.
    install(b, addPkgConfig(b, selection, target, release_version), .lib, "pkgconfig/luajit.pc");

    // Upstream's `COPYRIGHT`, at the root of the tree. A private repository
    // removes no upstream obligation, so the licence covering the compiled
    // archive ships beside it. Installed, not rewritten: a private repository
    // removes no licence text.
    install(
        b,
        b.path("COPYRIGHT"),
        .{ .custom = "share" },
        b.pathJoin(&.{ "doc", "luajit-" ++ graph.mm_version, "COPYRIGHT" }),
    );

    // This fork's own licence and provenance records, installed by the same graph
    // that installs the binary.
    //
    // They live here rather than in the Nix derivation so there is exactly one
    // writer per installed path: `package.nix` becomes a wrapper that invokes
    // `zig build install` and adds nothing, so a consumer cannot receive the
    // binary without the records that say what it is and under what terms.
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

/// The installed name of one public header, `luajit-2.1/<name>`.
///
/// `Makefile:42` is `INSTALL_DEFINC= $(DPREFIX)/include/luajit-$(MMVERSION)`, and
/// `Makefile:145` copies `$(FILES_INC)` into it flat, so a C consumer writes
/// `#include <lua.h>` with `etc/luajit.pc`'s `-I${includedir}` on the line.
fn headerDest(b: *std.Build, name: []const u8) []const u8 {
    return b.pathJoin(&.{ "luajit-" ++ graph.mm_version, name });
}

/// Whether this target's archive is linked against an external unwinder.
///
/// The same list `build_support/graph.zig` links `gcc_s` for, on the same
/// `std.Target.Os.Tag` axis, because the archive and the metadata that
/// describes it have to agree. A `Libs.private` that names the unwinder on a
/// target whose driver already links it is noise, and one that omits it on a
/// target whose driver does not is a static link that cannot close.
fn needsExternalUnwinder(target: std.Target) bool {
    return switch (target.os.tag) {
        .linux, .hurd, .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };
}

/// Renders `etc/luajit.pc` with `SED_PC`'s substitutions applied.
///
/// `Makefile:86-91` is three `sed -e` expressions rewriting `prefix=`,
/// `multilib=` and `relver=`, plus a fourth dropping `-Wl,-E` on Darwin. Each is
/// applied to the real template line here rather than to a copy of the file, so
/// a template change that this function does not handle is visible as an
/// unsubstituted line rather than as a silently wrong value.
///
/// `prefix=` is re-derived rather than substituted, which is the one place this
/// departs from upstream's rule: `SED_PC` writes `prefix=$(PREFIX)`
/// (`Makefile:88`), a literal root, and this build cannot know the root the
/// tree ends up under — `zig build install --prefix` writes wherever it is
/// told, and a Nix derivation writes into the store. So the installed file
/// names its own location instead. It lands at `<root>/lib/pkgconfig/luajit.pc`,
/// so `${pcfiledir}/../..` is `<root>`, and `pkg-config` resolves it when the
/// metadata is read. Everything downstream of it — `exec_prefix`, `libdir`, and
/// the `includedir` written just below — is written in terms of `${prefix}`
/// already (`etc/luajit.pc:10-13`), so those two lines are the only ones that
/// had a build-time root in them at all. A literal root would keep handing
/// every `-I` and `-L` to the build machine's directory layout after the tree
/// was copied anywhere else.
///
/// One more field is rewritten, and it is the one `SED_PC` does not touch.
/// `Libs.private` carries `-Wl,-E -lm -ldl` (`etc/luajit.pc:24`), which is what
/// a **shared** consumer needs, because `libluajit-5.1.so` carries its own
/// unwinder. `libluajit-5.1.a` does not: `LUAJIT_UNWIND_EXTERNAL`
/// (`src/Makefile:343`) is what makes `src/lj_err.c` declare six `_Unwind_*`
/// entry points and two frame-registration functions that nothing in the
/// archive defines, so a consumer that links the archive has to be told which
/// library does. Upstream leaves that to the compiler driver, which links
/// libgcc's unwinder by default; a driver that does not is this build, which is
/// why `build_support/graph.zig` links `gcc_s` for the ELF Unix targets itself.
/// Naming it here is what lets `pkg-config --static --libs` describe a link that
/// closes: `-Wl,-E -lm -ldl -lgcc_s` on the targets the graph names, and
/// upstream's three flags on every other one.
fn addPkgConfig(
    b: *std.Build,
    selection: abi.Selection,
    target: std.Target,
    release_version: []const u8,
) std.Build.LazyPath {
    const template = b.build_root.handle.readFileAlloc(
        b.graph.io,
        sources.pkg_config_template,
        b.allocator,
        .limited(1 << 16),
    ) catch |err| std.debug.panic(
        "luajit: cannot read the pkg-config template {s}: {s}",
        .{ sources.pkg_config_template, @errorName(err) },
    );

    // `INSTALL_LMOD=` and `INSTALL_CMOD=` are deliberately not rewritten.
    // `SED_PC` (`Makefile:86-90`) touches `prefix=`, `multilib=`, `relver=` and,
    // when `INSTALL_DEFINC != INSTALL_INC`, `includedir=` -- and nothing else --
    // and those two lines already read `${prefix}/share/lua/${abiver}` and
    // `${prefix}/${multilib}/lua/${abiver}` in the template
    // (`etc/luajit.pc:16-17`), out of the three variables substituted just above.
    // Writing a build machine's root into them is what this function exists to
    // avoid, and no consumer reads them: `Cflags:` is `-I${includedir}` and
    // `Libs:` is `-L${libdir} -l${libname}` (`etc/luajit.pc:25-26`). Upstream
    // installs both directories empty (`Makefile:47-50`, `:75`) and this build
    // installs neither.
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
            // `Makefile:118`: `SED_PC+= -e "s| -Wl,-E||"` for `Darwin iOS`.
            std.mem.trim(u8, line, " ")
        else if (needsExternalUnwinder(target) and
            std.mem.startsWith(u8, line, "Libs.private:"))
            // The archive's eight unwinder names, in the library the graph links
            // for this same target. Only a static consumer reads this field, and
            // a static consumer is the one that cannot close its link without it.
            b.fmt("{s} -lgcc_s", .{std.mem.trim(u8, line, " ")})
        else
            line;
        out.appendSlice(b.allocator, rendered) catch @panic("OOM");
        out.append(b.allocator, '\n') catch @panic("OOM");
    }

    const files = b.addWriteFiles();
    return files.add("luajit.pc", out.items);
}

/// Two C translation units compiled against the **installed** header tree and
/// linked against the **installed** library.
///
/// This is the only step that would catch a build in which the archive is right
/// but the headers a consumer sees are missing, stale, or installed in the wrong
/// directory -- a failure every in-tree gate passes.
///
/// The include path is `--prefix/include/luajit-2.1` and the library path is
/// `--prefix/lib`, which is exactly what `etc/luajit.pc` reports, so the step
/// exercises the same resolution a pkg-config-driven consumer performs. It
/// depends on the install step, so the tree it reads is the tree that step
/// wrote.
///
/// Two units, not one: a header set that only works from a single translation
/// unit has not had its macro definitions checked twice, and an archive that only
/// ever links from one unit can still be missing an object.
fn addHeaderCheck(b: *std.Build, linkage: std.builtin.LinkMode, selection: abi.Selection) void {
    const check_step = b.step(
        "header-check",
        "Compile and link two C translation units against the installed headers " ++
            "and library, then run the result",
    );

    // The install tree, by the paths `etc/luajit.pc` reports:
    // `includedir=${prefix}/include/luajit-${majver}.${minver}`
    // (`etc/luajit.pc:13`) and `libdir=${exec_prefix}/${multilib}`
    // (`etc/luajit.pc:11`) with `libname=luajit-${abiver}` (`etc/luajit.pc:12`).
    // Reading them as strings rather than as `std.Build.LazyPath`s is
    // deliberate: this program is an **external** C consumer, compiled by a
    // `zig cc` line that a reader can compare against `etc/luajit.pc` field by
    // field. Resolving it through a build module would hide those fields
    // behind graph plumbing, which is exactly the thing this step exists to
    // check.
    const prefix = b.getInstallPath(.prefix, "");
    const include_dir = b.fmt("{s}/include/luajit-{s}", .{ prefix, graph.mm_version });
    const lib_dir = b.fmt("{s}/lib", .{prefix});

    // A separate `Step.Compile` rather than a `Run` of a `zig cc` line: the
    // binary has to be a real build artifact, because it is what `addRunArtifact`
    // runs and what makes the install step a declared dependency of it.
    const mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    // The include path is `etc/luajit.pc:13`'s `includedir` verbatim, so the
    // step resolves headers exactly as a pkg-config-driven consumer would. It is
    // the install tree and not `src/`: a build whose archive is right but whose
    // installed headers are missing or stale passes every in-tree gate and fails
    // here, which is the only reason this step exists.
    mod.addIncludePath(.{ .cwd_relative = include_dir });
    mod.addLibraryPath(.{ .cwd_relative = lib_dir });
    // `etc/luajit.pc:23`, `Libs: -L${libdir} -l${libname}`, with
    // `libname=luajit-${abiver}` (`etc/luajit.pc:12`). The preferred mode follows
    // the `-Dlinkage` the rest of the build used, so a static install is not
    // asked for a `.so` that was never written.
    mod.linkSystemLibrary(graph.artifact_name, .{ .preferred_link_mode = linkage });
    // `etc/luajit.pc:24`, `Libs.private: -Wl,-E -lm -ldl`.
    mod.linkSystemLibrary("m", .{});
    switch (selection.os) {
        .linux, .other => mod.linkSystemLibrary("dl", .{}),
        else => {},
    }
    // A shared library must be findable at run time from a directory the binary
    // does not sit in. Without this the `-Dlinkage=dynamic` run would fail to
    // start for a reason that has nothing to do with the headers.
    if (linkage == .dynamic) mod.addRPath(.{ .cwd_relative = lib_dir });

    mod.addCSourceFile(.{ .file = b.path("build_support/header_check_a.c") });
    mod.addCSourceFile(.{ .file = b.path("build_support/header_check_b.c") });

    const program = b.addExecutable(.{ .name = "luajit-header-check", .root_module = mod });
    // The install step is a declared dependency, not a coincidence: the two
    // paths above name the install tree, so the compile must not read a tree
    // that has not been written.
    program.step.dependOn(b.getInstallStep());

    const run = b.addRunArtifact(program);
    run.setName("run the installed-header C consumer");
    run.has_side_effects = true;
    check_step.dependOn(&run.step);
}
