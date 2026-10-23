// SPDX-License-Identifier: MIT
//! How one target's LuaJIT graph is assembled: the host toolchain, the
//! generators, the library, the CLI and the installed closure.
//!
//! `build.zig` decides which steps exist. Everything that turns a
//! (target, optimize) pair into compiled artifacts lives here, so the published
//! graph and each of the cross-target checks are built by the same code.
//!
//! ## What is generated, and by which upstream program
//!
//! LuaJIT is not a C library with a `configure` step. Its inputs include
//! programs that run on the **host** and emit code shaped for the **target**,
//! and every one of them is upstream's own:
//!
//! | output | upstream program | upstream rule |
//! |---|---|---|
//! | `luajit.h` | `minilua host/genversion.lua` | `src/Makefile:670-673` |
//! | `luajit_relver.txt` | `cat ../.relver`, the non-git branch | `src/Makefile:495` |
//! | `host/buildvm_arch.h` | `minilua dynasm/dynasm.lua vm_<arch>.dasc` | `src/Makefile:675-677` |
//! | `lj_vm.S` or `lj_vm.obj` | `buildvm -m elfasm\|machasm\|peobj` | `src/Makefile:685-687` |
//! | `lj_bcdef.h` | `buildvm -m bcdef` | `src/Makefile:689-691` |
//! | `lj_ffdef.h` | `buildvm -m ffdef` | `src/Makefile:693-695` |
//! | `lj_libdef.h` | `buildvm -m libdef` | `src/Makefile:697-699` |
//! | `lj_recdef.h` | `buildvm -m recdef` | `src/Makefile:701-703` |
//! | `jit/vmdef.lua` | `buildvm -m vmdef` | `src/Makefile:705-707` |
//! | `lj_folddef.h` | `buildvm -m folddef` | `src/Makefile:709-711` |
//!
//! The first five `buildvm` modes all take the same argument list,
//! `$(LJLIB_C)` (`src/Makefile:515-516`), and `folddef` takes `lj_opt_fold.c`
//! alone. Nothing here invents a table: it scans the same source files with the
//! same program.
//!
//! ## The ordering the graph has to keep
//!
//! `buildvm` cannot be built before `luajit.h` and `host/buildvm_arch.h` exist,
//! and `buildvm` is what produces five of the headers the library needs. The
//! order is therefore:
//!
//! 1. `minilua` (host)
//! 2. `luajit.h` and `host/buildvm_arch.h`, both from `minilua`
//! 3. `buildvm` (host), compiled against those two
//! 4. the six `buildvm` outputs, including the VM
//! 5. the library, then the CLI
//!
//! Zig resolves that through `LazyPath` step dependencies rather than by
//! sequencing: every generated path is the output of a `Run` step, and every
//! compilation that needs one names it as an include path or a file input, so
//! the graph orders them. No generated file is written during the build
//! function; all of them resolve in dependent steps, as `AGENTS.md` § 5 requires.
//!
//! ## `buildvm` is a host program configured for the target
//!
//! `src/Makefile:203` puts `$(TARGET_ARCH)` on `HOST_ACFLAGS`, so upstream's
//! `buildvm` binary is compiled **for the host** while being told the **target's**
//! architecture: `-DLUAJIT_TARGET=LUAJIT_ARCH_x64`, `-DLJ_ARCH_HASFPU=`,
//! `-DLJ_ABI_SOFTFP=` and the rest, all accumulated at `src/Makefile:244-287` and
//! `:428-453`. `src/Makefile:364-382` adds the target's `LUAJIT_OS_*` to the host
//! line too when the two differ. That is what lets one host build a foreign
//! target's VM, and this graph does the same: the generators are built for a
//! **host** target, never for the target. `minilua` takes `b.graph.host` as it
//! is; `buildvm` takes `generatorHostTarget`, which is the host unless the
//! target's pointer width is different -- `src/host/buildvm.c:449-453` refuses
//! to run a `buildvm` whose `sizeof(void*)` disagrees with the `LJ_32`/`LJ_64`
//! this graph pins, which is what upstream answers with
//! `HOST_CC="gcc -m32"` (`src/Makefile:32`, `:187-188`).

const std = @import("std");
const abi = @import("abi.zig");
const sources = @import("sources.zig");
/// The runtime-loading route: the generated dispatch, the loader core and this
/// SDK's descriptor. Owned by the API role; `runtime/graph.zig` documents the
/// substitution this file performs and what a caller must not do with it.
const runtime_graph = @import("../runtime/graph.zig");

/// Upstream `MAJVER` and `MINVER` (`Makefile:16-17`).
pub const major_version = 2;
pub const minor_version = 1;
/// Upstream `ABIVER` (`Makefile:18`): the Lua ABI LuaJIT implements. It appears
/// in every installed file name upstream writes (`libluajit-5.1.a`,
/// `include/luajit-2.1`) and in the `luajit-5.1` pkg-config library name.
pub const abi_version = "5.1";

/// `MAJVER.MINVER` (`Makefile:25`, `$(MMVERSION)`): the installed header
/// directory and the `jit` module directory.
pub const mm_version = "2.1";

/// The tracked rolling-version stamp at the package root: upstream's own file,
/// named in `.gitattributes` as `export-subst`, in `build.zig.zon`'s `.paths`
/// and in `UPSTREAM.sha256`.
const relver_file = ".relver";

/// The rolling release version, `$(RELVER)` (`Makefile:22`), read from
/// `relver_file`.
///
/// Upstream's `GIT_RELVER` (`src/Makefile:495`) writes `git show -s
/// --format=%ct` into `luajit_relver.txt` when a `.git` directory is present and
/// `cat ../.relver` into it otherwise. This build is always the second branch:
/// there is no `git` step, no `git describe` and no build-time download, so
/// that file is the only place the number exists, and reading it here is what
/// makes `build.zig.zon`'s claim that the relver comes from `.relver` rather
/// than from git true of the whole build and not just of the header.
///
/// For the pinned snapshot `c6ffc141a8762b41703f9287d63d93622a13dd8f` the file
/// holds `1788856981`, the commit's POSIX timestamp (2026-09-08T08:43:01Z),
/// which is what the driver recorded at
/// `local://foundation-contract-luajit-snapshot.json`. No copy of those digits
/// is written here: `genversion.lua:33-36` substitutes them for `ROLLING` in
/// `luajit_rolling.h:33-35`, so `LUAJIT_VERSION` reads `LuaJIT 2.1.<relver>`
/// and `LUAJIT_VERSION_SYM` becomes `luaJIT_version_2_1_<relver>`. That symbol
/// is upstream's linker-level version check (`luajit_rolling.h:77`): a program
/// built against one revision and run against another fails to link rather
/// than disagreeing at run time.
///
/// Read once, while the graph is being configured, and handed to every
/// consumer through `Options`. All three of them -- the generated header,
/// `luajit.pc`'s `relver=` and a shared library's version -- need it as a
/// plain string at that point, not as a step's output, so it cannot be
/// produced by a step and threaded through.
pub fn releaseVersion(b: *std.Build) []const u8 {
    // `b.root` is this package's Cache.Path, including when used by a consumer
    // dependency, so it resolves the same tracked stamp in either context.
    // `addPkgConfig` reads its template through the same root directory.
    b.dependOnFileContents(b.path(relver_file));
    // Owned by `b.allocator`, which outlives the graph this value is read for,
    // so the trimmed slice below is returned without a second copy.
    var root_dir = b.root.openDir(b.graph.io, ".", .{}) catch |err| std.debug.panic(
        "luajit: cannot open the build root: {s}",
        .{@errorName(err)},
    );
    defer root_dir.close(b.graph.io);
    const raw = root_dir.readFileAlloc(
        b.graph.io,
        relver_file,
        b.allocator,
        .limited(1 << 10),
    ) catch |err| std.debug.panic(
        "luajit: cannot read {s}: {s}",
        .{ relver_file, @errorName(err) },
    );
    const digits = std.mem.trim(u8, raw, " \t\r\n");
    if (digits.len == 0)
        std.debug.panic("luajit: {s} is empty", .{relver_file});
    for (digits) |c| {
        // `src/host/genversion.lua:33` takes the first run of digits with
        // `:match("(%d+)"`, so anything else in this file would be silently
        // dropped by the generator. Refused here instead.
        if (!std.ascii.isDigit(c))
            std.debug.panic("luajit: {s} holds '{s}', which is not a Unix commit timestamp", .{ relver_file, digits });
    }
    return digits;
}

/// The version a shared library carries in its file name and its `SONAME`.
///
/// Upstream installs three names for one object. On ELF they are
/// `INSTALL_SONAME` `libluajit-$(ABIVER).so.$(VERSION)`, `INSTALL_SOSHORT2`
/// `libluajit-$(ABIVER).so.$(MAJVER)` and `INSTALL_SOSHORT1`
/// `libluajit-$(ABIVER).so` (`Makefile:56-59`); on Darwin the same three are
/// `INSTALL_DYLIBNAME`, `INSTALL_DYLIBSHORT2` and `INSTALL_DYLIBSHORT1`
/// (`Makefile:60-62`), with `.dylib` where the ELF names have `.so` and
/// `$(MAJVER)` where the ELF names have `$(VERSION)` or nothing.
/// `std.Build.Step.Compile` derives exactly that triple from one `version`
/// (`std/Build/Step/Compile.zig:490-507`) and creates the two symlinks where
/// it installs (`:1823-1832`).
///
/// It is set unconditionally, not only under `-Dlinkage=dynamic`, because Zig
/// consumes it only for a shared object (`std/Build/Step/Compile.zig:488-489`)
/// and gives a static archive the same `libluajit-5.1.a` name either way. Left
/// unset, the shared object carries no `SONAME` at all, and every dependent
/// that links it records the build machine's output path in its `DT_NEEDED`.
pub fn libraryVersion(b: *std.Build, release_version: []const u8) std.SemanticVersion {
    // `Makefile:26`: `VERSION= $(MMVERSION).$(RELVER)`.
    const full = b.fmt("{s}.{s}", .{ mm_version, release_version });
    return std.SemanticVersion.parse(full) catch |err| std.debug.panic(
        "luajit: '{s}' is not a MAJVER.MINVER.RELVER version: {s}",
        .{ full, @errorName(err) },
    );
}

/// The published artifact name, and the `-l` name a C consumer uses.
///
/// Upstream's `libname=luajit-${abiver}` (`etc/luajit.pc:12`) and
/// `-lluajit-5.1`. Zig prefixes `lib` and the suffix itself, so the artifact is
/// named `luajit-5.1` and the installed files are `libluajit-5.1.a` on a static
/// build and `libluajit-5.1.so*` on a shared one -- upstream's `INSTALL_ANAME`
/// and `INSTALL_SONAME` (`Makefile:56-59`).
pub const artifact_name = "luajit-" ++ abi_version;

const host_cflags: []const []const u8 = &.{ "-O2", "-fno-strict-float-cast-overflow" };

/// Options every graph this file builds shares.
pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    /// Whether this is the published package module set or a private one. A
    /// cross-target check needs the private form: modules are registered by
    /// name against the whole build, so registering `luajit` once per check
    /// target would leave only the last reachable.
    public: bool,
    /// The artifact name. The published graph uses the name a user types; a
    /// check graph adds the target triple, because six steps all called
    /// `luajit-5.1` make `--summary all` unreadable.
    name_prefix: []const u8,
    linkage: std.lang.LinkMode,
    /// `$(RELVER)` (`Makefile:22`), read once by `releaseVersion` from the
    /// tracked `.relver` and carried here so the generated header, the
    /// `relver=` line of `luajit.pc` and a shared library's version are three
    /// renderings of one read rather than three copies of one literal.
    release_version: []const u8,
    /// Build the CLI. The published graph does; a cross-target check of a
    /// foreign target cannot run it, so `check` compiles the library and the
    /// facade only.
    with_cli: bool,
    /// The absolute install root to compile into the binary as `LUA_ROOT`,
    /// `LUA_LJDIR` and `LUA_MULTILIB`, or null to define none of them.
    ///
    /// Upstream takes this from its `PREFIX` variable (`Makefile:33`,
    /// `src/Makefile:288-304`) and defaults it to `/usr/local`. It has to be an
    /// absolute path: `LUA_PATH_DEFAULT` (`luaconf.h:63-64`) is a runtime search
    /// path, and a relative one would be resolved against whatever directory the
    /// CLI happened to be started from. Null reproduces upstream's documented
    /// distribution layout, where `luaconf.h:37` supplies `/usr/local` and the
    /// build passes no root at all -- `doc/install.html#distro` is upstream's own
    /// instruction to do exactly that rather than patch `luaconf.h`.
    lua_root: ?[]const u8,
    /// Resolve the native symbols through the platform loader at run time
    /// instead of linking the archive into the facade.
    ///
    /// Orthogonal to `linkage`: it changes where the *facade's* calls go, not
    /// what kind of artifact the library is. The library is still built, still
    /// installed, and is still the thing a runtime build loads at run time.
    runtime_loaded: bool,
    /// Also build the second copy of the CLI: the one whose loader is the build
    /// cache rather than the install tree.
    ///
    /// `bin/luajit` is installed *and* driven by `native-test`, and one binary
    /// cannot carry both search paths, so the published graph asks for both.
    /// A cross-target check does not, because nothing in that matrix runs and
    /// nothing in it is installed. The facade needs no such flag: the published
    /// module already carries the build cache's entry, which is the entry every
    /// program built from it has to have.
    for_cache_runs: bool = false,
};

/// Everything one target's graph produces.
pub const Graph = struct {
    /// The native library, static or shared as `Options.linkage` says.
    library: *std.Build.Step.Compile,
    /// The `luajit` CLI as it is installed, or null when `Options.with_cli`
    /// was false.
    cli: ?*std.Build.Step.Compile,
    /// The copy of the CLI the `native-test` step executes. The same program
    /// built from the same sources against the build-cache flavour of the
    /// library link; `cli` itself when the two are the same file.
    run_cli: ?*std.Build.Step.Compile,
    /// The facade module, published as `luajit` or created privately. It
    /// carries the build cache's entry, which is what every program built from
    /// it needs: the tests, the smoke example, and any dependent.
    module: ?*std.Build.Module,
    /// The generated `luajit.h`, also installed.
    version_header: std.Build.LazyPath,
    /// The generated `jit/vmdef.lua`, also installed.
    vmdef_lua: std.Build.LazyPath,
    /// The directory every `buildvm` header is written into.
    generated_dir: std.Build.LazyPath,
    /// This target's ABI selection, for the callers that need the output names.
    selection: abi.Selection,
};

/// Build the whole graph for one target.
pub fn addGraph(b: *std.Build, o: Options) !Graph {
    const target = try abi.select(o.target.result);

    // --- step 1: the host tool that needs no generated input ---------------
    const minilua = addMinilua(b);

    // --- step 2: the two `minilua` outputs ---------------------------------
    const version_header = addVersionHeader(b, minilua, o.release_version);
    const buildvm_arch = addBuildvmArch(b, minilua, target);

    // --- step 3: `buildvm`, which needs both of those ----------------------
    const buildvm = addBuildvm(b, target, o, version_header, buildvm_arch);

    // --- step 4: the `buildvm` outputs -------------------------------------
    const defs = addBuildvmOutputs(b, buildvm, version_header);
    const vm = addVmOutput(b, buildvm, target);

    // --- step 5: the library, the CLI and the facade -----------------------
    const library = addLibrary(b, o, target, defs, vm);

    // `bin/luajit` is installed *and* executed by `native-test`, and one binary
    // cannot carry both search paths, so when the caller asks for it the CLI is
    // compiled twice from one description. A static archive, an import-library
    // link on COFF and a runtime-loading graph all produce the same file either
    // way, and `needsBothLoaders` is what says so. The CLI is C and links the
    // library through a module of its own, which is why it takes a `Loader`
    // argument while the facade below does not.
    const both_loaders = o.for_cache_runs and
        needsBothLoaders(if (o.runtime_loaded) null else library, o.target);
    const cli: ?*std.Build.Step.Compile = if (o.with_cli)
        addCli(b, o, target, library, defs, .install_tree)
    else
        null;
    const run_cli: ?*std.Build.Step.Compile = if (both_loaders)
        addCli(b, o, target, library, defs, .build_cache)
    else
        cli;

    // One `TranslateC` step serves both configurations. It is built once here,
    // from `build_support/translate.h` and this target's macros and include
    // paths, and each configuration decides what to hand it to:
    //
    //   linked   `translate.createModule()` -- the header's own declarations,
    //            resolved through the archive this graph builds.
    //   runtime  `runtime/graph.zig`'s generated dispatch, which re-exports that
    //            same namespace as `c_native` and resolves the calls through the
    //            platform loader instead.
    //
    // `zig/root.zig` asks which one it is with
    // `if (@hasDecl(c, "rt_runtime_loaded"))` (`zig/root.zig:213`), so one facade
    // source compiles either way and no consumer sees two incompatible shapes.
    const translate = addTranslate(b, o, target, version_header, defs);

    const module: ?*std.Build.Module = if (o.public)
        b.addModule("luajit", .{
            .root_source_file = b.path("zig/root.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
        })
    else
        b.createModule(.{
            .root_source_file = b.path("zig/root.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
        });
    var rt_core: ?*std.Build.Module = null;
    if (module) |m| {
        // Imported, never registered: `addModule("c")` would make
        // `dep.module("c")` resolve and hand a dependent the same declarations
        // with no library behind them. `c` on the facade is the supported way in.
        if (o.runtime_loaded) {
            // The dispatch links **no** archive. That is the whole point of the
            // configuration: the symbols arrive through the platform loader at
            // run time, and linking the library as well would make the linker
            // demand them before `load` ever runs. So there is deliberately no
            // `linkLibrary` on this branch, and adding one would silently turn
            // a runtime build back into a linked one.
            //
            // `rt` is not imported either. `zig/root.zig:222-228` reaches for
            // `rt.LoadSource` and `rt.LoadError` only where `runtime_loaded` is
            // false; in this configuration it reads both off the dispatch, so
            // an unresolved `rt` is never referenced.
            m.addImport("c", runtime_graph.createModule(b, translate, o.target, o.optimize));
        } else {
            m.addImport("c", translate.createModule());
            // The reusable loader core, `runtime/loader.zig`, supplies the two
            // public types a linked build still has to publish. They come from
            // the shared core rather than being restated, so a consumer sees one
            // `LoadSource` whichever configuration built it. One core per build
            // and not one per facade, because two cores would be two sets of
            // those two types.
            rt_core = runtime_graph.createCoreModule(b, o.target, o.optimize);
            m.addImport("rt", rt_core.?);
            // The facade is the module every program of this build imports --
            // the tests, the smoke example, and any downstream consumer of the
            // package -- and every module in a compilation's graph contributes
            // its own rpaths, so the search path is decided here, once, for
            // every program built from it. Which path that is belongs to
            // `Loader`, and this is the published module, so it is the
            // `build_cache` one: a dependent's executable is built out of a
            // build cache and finds the shared object in the directory Zig
            // baked in. No program of this package is installed from this
            // facade -- `bin/luajit` is C and has a module of its own, built by
            // `addCli`.
            linkForLoader(m, library, o.target, .build_cache);
        }
        // The same two include paths the library was compiled with, so a
        // dependent that compiles its own C against this module resolves the
        // same `lua.h` and the same generated `luajit.h` the archive was built
        // from. Stated in both configurations: the dispatch is compiled in this
        // same tree even though it links no archive.
        m.addIncludePath(b.path("src"));
        m.addIncludePath(defs.generated_dir);
    }

    // There is no second facade. The published module above is the one every
    // program imports, and it already carries the build cache's entry, which is
    // the entry a test binary and a smoke example need and the only entry a
    // dependent can use. An install-tree facade would exist only for an
    // installed program built from this module, and `bin/luajit` is not one:
    // it is compiled from `src/luajit.c` against a module of its own, which is
    // where its `Loader` argument goes.

    return .{
        .library = library,
        .cli = cli,
        .run_cli = run_cli,
        .module = module,
        .version_header = version_header,
        .vmdef_lua = defs.vmdef,
        .generated_dir = defs.generated_dir,
        .selection = target,
    };
}

/// Whether the Windows DLL decoration macro applies.
///
/// `luaconf.h:129-134` switches `LUA_API` between `__declspec(dllexport)` and
/// `__declspec(dllimport)` on `LUA_BUILD_AS_DLL`. Upstream adds it at
/// `src/Makefile:573` in the mode that produces a DLL. This build honours
/// `-Dlinkage` on every platform instead of forcing dynamic on Windows as
/// `src/Makefile:569-574` does, so the macro follows the linkage the caller
/// chose. It is a declaration change, so it goes on the translation line too.
fn needsDllMacro(target: abi.Selection, linkage: std.lang.LinkMode) bool {
    return target.os == .windows and linkage == .dynamic;
}

/// The `-D` set `TARGET_ARCH` carries (`src/Makefile:244-287`, `:428-453`),
/// applied to a module.
///
/// `abi.targetArchMacros` returns `NAME=VALUE` strings. A bare `NAME` means an
/// object-like macro defined empty, which is what `addCMacro(name, "")` emits and
/// what `-DNAME` on a command line means.
fn applyTargetArchMacros(m: *std.Build.Module, target: abi.Selection, b: *std.Build) void {
    for (abi.targetArchMacros(target, b.allocator)) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=')) |i| {
            m.addCMacro(entry[0..i], entry[i + 1 ..]);
        } else {
            m.addCMacro(entry, "");
        }
    }
}

/// `minilua`, compiled for the host.
///
/// `src/Makefile:392-393` compiles `host/minilua.c` into `host/minilua.o` and
/// links it with `MINILUA_LIBS=-lm`. `src/host/minilua.c` is checked in: it is
/// upstream's minified Lua 5.1.5 amalgamation, produced by
/// `src/host/genminilua.lua`, which needs a Lua 5.1.5 source tree this
/// repository does not carry and this build does not fetch. The generated file
/// upstream ships is the file upstream's own rule compiles.
///
/// It is target-independent: `genversion.lua` and `dynasm.lua` are its scripts
/// and neither takes an architecture input from the compiler
/// (`src/host/genversion.lua:31-36`; `dynasm/dynasm.lua` reads only its `-D`
/// arguments). One host build therefore serves every target, and building it
/// once per target graph is what keeps each graph self-contained.
fn addMinilua(b: *std.Build) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .fast,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("src"));
    // Match Makefile's host -O2 profile. Minilua hashes out-of-range numeric
    // keys by converting to int and comparing back; retain hardware conversion
    // rather than Clang's strict float-cast overflow assumptions.
    mod.addCSourceFile(.{
        .file = b.path(b.pathJoin(&.{ "src", sources.minilua_source })),
        .flags = host_cflags,
    });
    // `src/Makefile:393`: `MINILUA_LIBS= -lm`.
    mod.linkSystemLibrary("m", .{});
    return b.addExecutable(.{ .name = "luajit-minilua", .root_module = mod });
}

/// `luajit.h`, from `minilua host/genversion.lua`.
///
/// `src/Makefile:670-673` writes `luajit_relver.txt` first and then runs
/// `$(HOST_LUA) host/genversion.lua`. The script reads `luajit_rolling.h` and
/// `luajit_relver.txt` from the working directory and writes `luajit.h` beside
/// them (`src/host/genversion.lua:9-11`, `:32-44`), so this passes all three as
/// explicit arguments -- `arg[1]`, `arg[2]` and `arg[3]` at
/// `src/host/genversion.lua:8-11` -- rather than relying on a working directory
/// that would have to hold a copy of `luajit_rolling.h`.
fn addVersionHeader(
    b: *std.Build,
    minilua: *std.Build.Step.Compile,
    release_version: []const u8,
) std.Build.LazyPath {
    const stamp = b.addWriteFiles();

    // `src/Makefile:495`'s non-git branch, `cat ../.relver`, with the digits
    // `releaseVersion` read out of that file. The trailing newline is this
    // build's, not the file's: upstream `cat`s the bytes through verbatim and
    // `genversion.lua:33` takes the first run of digits either way, so the one
    // line this writes is what `src/.gitignore:3` expects to find. Written
    // through `addWriteFiles` so it lands in the build cache and never in the
    // source tree.
    const relver = stamp.add("luajit_relver.txt", b.fmt("{s}\n", .{release_version}));

    const run = b.addRunArtifact(minilua);
    run.setName("genversion");
    // addFileArg2 records each source as a file input so changes re-run the step.
    run.addFileArg2(b.path(b.pathJoin(&.{ "src", "host", "genversion.lua" })), .{});
    // `src/host/genversion.lua:32`: `file_read(FILE_ROLLING_H)`.
    run.addFileArg2(b.path(b.pathJoin(&.{ "src", "luajit_rolling.h" })), .{});
    // `src/host/genversion.lua:33`: `file_read(FILE_RELVER_TXT)`.
    run.addFileArg2(relver, .{});
    // `src/host/genversion.lua:44`: `file_write_mod(FILE_LUAJIT_H, text)`. The
    // script writes only when the bytes differ (`src/host/genversion.lua:20-26`),
    // which is why a cached run is still correct output.
    return run.addOutputFileArg2(sources.version_generated_header, .{});
}

/// `host/buildvm_arch.h`, from `minilua dynasm/dynasm.lua vm_<arch>.dasc`.
///
/// `src/Makefile:675-677` makes this depend on `$(DASM_DASC)`, `lj_arch.h`,
/// `lua.h` and `luaconf.h`; each is recorded as a file input so a change to any
/// of them re-runs DynASM. The `-D` list is `DASM_AFLAGS`
/// (`src/Makefile:409-486`), which `abi.dynasmDefines` reproduces.
///
/// `dynasm/dynasm.lua:1077-1081` adds the script's own directory to
/// `package.path`, so passing `dynasm/dynasm.lua` by path is what lets
/// `loadarch` (`:631-638`) `require("dasm_"..arch)` find the backend beside it.
fn addBuildvmArch(
    b: *std.Build,
    minilua: *std.Build.Step.Compile,
    target: abi.Selection,
) std.Build.LazyPath {
    const run = b.addRunArtifact(minilua);
    run.setName(b.fmt("dynasm {s}", .{target.dasc_source}));
    // addFileArg2 records each source as a file input so changes re-run DynASM.
    run.addFileArg2(b.path(b.pathJoin(&.{ "dynasm", "dynasm.lua" })), .{});
    for (abi.dynasmDefines(target, b.allocator)) |d| {
        // Two argv elements, `-D` and `NAME` or `NAME=VALUE`, because
        // `dynasm/dynasm.lua:196-205` reads the define as `optparam(args)`, the
        // argument after the flag -- exactly how `src/Makefile:405-486` spells
        // it.
        run.addArg("-D");
        run.addArg(d);
    }
    run.addArg("-o");
    const out = run.addOutputFileArg2(std.fs.path.basename(sources.dynasm_generated_header), .{});
    // `src/Makefile:489`, `DASM_DASC= vm_$(DASM_ARCH).dasc`.
    run.addFileArg2(b.path(b.pathJoin(&.{ "src", target.dasc_source })), .{});
    // `src/Makefile:675`'s remaining prerequisites.
    run.addFileInput(b.path(b.pathJoin(&.{ "src", "lj_arch.h" })));
    run.addFileInput(b.path(b.pathJoin(&.{ "src", "lua.h" })));
    run.addFileInput(b.path(b.pathJoin(&.{ "src", "luaconf.h" })));
    return out;
}

/// The target the *host* generators are compiled for.
///
/// `buildvm` is a host program -- it scans source text and writes files -- and
/// `src/Makefile:187-188` documents the two worked cross examples with
/// `HOST_CC="gcc -m32"`, one of which is `CROSS=powerpc-linux-gnu-`. What that
/// `-m32` buys is `src/host/buildvm.c:449-453`:
///
/// ```c
///   if (sizeof(void *) != 4*LJ_32+8*LJ_64) {
///     fprintf(stderr,"Error: pointer size mismatch in cross-build.\n");
///     fprintf(stderr,"Try: make HOST_CC=\"gcc -m32\" CROSS=...\n\n");
/// ```
///
/// `LJ_32` and `LJ_64` are the *target's* (`lj_arch.h:671-677`), pinned on the
/// generator's compile line by `applyTargetArchMacros`, so upstream's rule and
/// this one are the same rule: a 32-bit target needs a **32-bit generator**.
/// Selecting the build machine's own pointer width is what upstream's `-m32`
/// means; `std.Target.ptrBitWidth()` (`std/Target.zig:2913`) is what decides it
/// here.
///
/// The 32-bit generator is the host's own system with a 32-bit CPU, so it is a
/// program of the build machine's family and runs on the build machine wherever
/// that family's execution mode is available. On Linux it is built against musl
/// and therefore links statically: a 32-bit *glibc* is something a build machine
/// can be assumed to carry, and a statically linked program has no dynamic
/// loader for an executor to find. Elsewhere the host's own C ABI is kept, and
/// Zig reports any combination it cannot resolve.
///
/// `minilua` is deliberately not on this route: `src/host/minilua.c` includes
/// C library headers only, and `src/host/genversion.lua` and
/// `dynasm/dynasm.lua` read text and `-D` arguments, so the interpreter that
/// produces `luajit.h` and `buildvm_arch.h` has no width to disagree about.
fn generatorHostTarget(b: *std.Build, target: abi.Selection) std.Build.ResolvedTarget {
    const host = b.graph.host;
    const host_bits: u16 = host.result.ptrBitWidth();
    // `lj_arch.h:671-677` turns `LJ_ARCH_BITS` into exactly this pair.
    const target_bits: u16 = target.bits;
    if (host_bits == target_bits) return host;
    if (target_bits != 32) std.debug.panic(
        "luajit: {s} is a {d}-bit target and this build machine is {d}-bit; " ++
            "buildvm needs a generator with the target's pointer width " ++
            "(src/host/buildvm.c:449-453)",
        .{ @tagName(target.arch), target_bits, host_bits },
    );
    const arch: std.Target.Cpu.Arch = switch (host.result.cpu.arch) {
        // Same family, 32-bit wide: what `-m32` selects on this machine.
        .x86_64 => .x86,
        .aarch64 => .arm,
        .aarch64_be => .armeb,
        .powerpc64 => .powerpc,
        .powerpc64le => .powerpcle,
        .powerpc => .powerpc,
        .powerpcle => .powerpcle,
        .mips64 => .mips,
        .mips64el => .mipsel,
        .mips => .mips,
        .mipsel => .mipsel,
        .riscv64 => .riscv32,
        .riscv64be => .riscv32be,
        .riscv32 => .riscv32,
        .riscv32be => .riscv32be,
        else => |other| std.debug.panic(
            "luajit: no 32-bit generator for a {s} build machine. A 32-bit " ++
                "target needs a 32-bit buildvm (src/host/buildvm.c:449-453); " ++
                "upstream's route for it is HOST_CC=\"gcc -m32\" (src/Makefile:32, :187-188).",
            .{@tagName(other)},
        ),
    };
    return b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = host.result.os.tag,
        .abi = if (host.result.os.tag == .linux) .musl else host.result.abi,
    });
}

/// Whether a target's own C toolchain reports `TARGET_OS_IPHONE`.
///
/// `lj_arch.h:130-133` keys `LJ_TARGET_IOS` on it, and Apple's toolchain
/// defines it for the mobile family and for Mac Catalyst, which runs iOS code
/// on macOS. `TARGET_OS_MACCATALYST` is not an alternative spelling of
/// `TARGET_OS_IPHONE` (`lj_arch.h:130` reads only the latter), so a Catalyst
/// target reaches `LJ_TARGET_IOS 1` exactly as an iOS target does.
fn targetIsAppleMobile(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .ios, .maccatalyst, .tvos, .watchos, .visionos => true,
        else => false,
    };
}

/// Compile `buildvm` against the two generated files, for the host target
/// `generatorHostTarget` selects -- the build machine itself, or a 32-bit
/// build machine when the target is 32 bits.
fn addBuildvm(
    b: *std.Build,
    target: abi.Selection,
    o: Options,
    version_header: std.Build.LazyPath,
    buildvm_arch: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const generator = generatorHostTarget(b, target);
    const mod = b.createModule(.{
        // The generator runs on the build machine and is configured for the
        // target, so its pointer width is the one `generatorHostTarget` chooses
        // and not the build machine's by default.
        .target = generator,
        .optimize = .fast,
        .link_libc = true,
    });
    // `src/Makefile:200`: `HOST_XCFLAGS= -I.`, which in upstream's own build is
    // `src/`. `src/Makefile:203` adds `$(TARGET_ARCH)`, and
    // `src/Makefile:679` makes `host/buildvm.o` depend on `$(DASM_DIR)/dasm_*.h`,
    // so `dynasm/` is on the path too.
    mod.addIncludePath(b.path("src"));
    mod.addIncludePath(b.path("src/host"));
    mod.addIncludePath(b.path("dynasm"));
    // `src/host/buildvm.c:31` includes `"luajit.h"` and `:75` includes
    // `"buildvm_arch.h"` by bare name, so both generated directories are on the
    // include path rather than named as explicit inputs.
    mod.addIncludePath(version_header.dirname());
    mod.addIncludePath(buildvm_arch.dirname());
    applyTargetArchMacros(mod, target, b);
    // `src/Makefile:364-382`: when the host and target OS differ, upstream adds
    // the target's `LUAJIT_OS_*` to the host compile line. `host/buildvm.c:33`
    // and `host/buildvm_asm.c` both branch on it.
    if (b.graph.host.result.os.tag != o.target.result.os.tag) {
        const entry = abi.osMacro(target, b.allocator);
        const eq = std.mem.indexOfScalar(u8, entry, '=').?;
        mod.addCMacro(entry[0..eq], entry[eq + 1 ..]);
        // `src/Makefile:362` guards the whole block on the host and target
        // *systems* differing, and its iOS arm is
        // `-DLUAJIT_OS=LUAJIT_OS_OSX -DLUAJIT_TARGET_IPHONE=1`
        // (`src/Makefile:373-376`). That second define is what makes the
        // generator agree with the library about the JIT:
        // `src/host/buildvm_lib.c:379-395` scans `lib_jit.c` with
        // `#if LJ_HASJIT` resolved from *buildvm's own* `lj_arch.h`, and
        // `lj_arch.h:130-133` reads the target's `TARGET_OS_IPHONE` when the
        // library is compiled but the build machine's when the generator is.
        // Without the define, a generator on a non-Apple host sees
        // `LJ_HASJIT 1` and writes the `jit.util` entries into
        // `lj_libdef.h` that the target's `lib_jit.c`, compiled with
        // `LJ_HASJIT 0`, never defines.
        //
        // Pinned on the generator's line only. The library's own toolchain
        // already answers `TARGET_OS_IPHONE` there, and restating it would be a
        // claim about a target this graph cannot see.
        if (targetIsAppleMobile(o.target.result.os.tag)) {
            mod.addCMacro("LUAJIT_TARGET_IPHONE", "1");
        }
    }
    // `src/Makefile:336`: `-fno-omit-frame-pointer` on iOS arm64.
    if (o.target.result.os.tag.isDarwin() and o.target.result.cpu.arch == .aarch64) {
        mod.omit_frame_pointer = false;
    }
    // `src/Makefile:499-502`.
    for (sources.buildvm_sources) |s| mod.addCSourceFile(.{
        .file = b.path(b.pathJoin(&.{ "src", s })),
        .flags = host_cflags,
    });
    mod.linkSystemLibrary("m", .{});
    // A narrowed generator is a 32-bit program, and a dynamic one with a
    // declared `/lib/ld-musl-i386.so.1` is what sixteen observed cross cells
    // failed on. Static linkage leaves the artifact with no PT_INTERP, so nothing
    // asks the kernel for that loader; a kernel whose 32-bit execution mode is
    // unavailable is handled by `addRunGenerator` below, under the caller's
    // explicit `-fqemu`, not by the target's metadata.
    const narrowed = generator.result.ptrBitWidth() != b.graph.host.result.ptrBitWidth();
    return b.addExecutable(.{
        .name = "luajit-buildvm",
        .linkage = if (narrowed and b.graph.host.result.os.tag == .linux) .static else null,
        .root_module = mod,
    });
}

/// Lets Zig's run step select an enabled external executor for host generators.
fn addRunGenerator(b: *std.Build, buildvm: *std.Build.Step.Compile) *std.Build.Step.Run {
    return b.addRunArtifact(buildvm);
}

/// The VM output, from `buildvm -m <mode> -o <out>`.
///
/// `src/Makefile:685-687` writes `lj_vm.S` for `elfasm` and `machasm`. For
/// Windows `LJVM_BOUT` (`src/Makefile:512`, `:561`) is `lj_vm.o`, so `buildvm`
/// writes a PE object that is linked as an object, because upstream states it
/// cannot assume a suitable assembler is present
/// (`src/host/buildvm_peobj.c:1-6`).
fn addVmOutput(
    b: *std.Build,
    buildvm: *std.Build.Step.Compile,
    target: abi.Selection,
) std.Build.LazyPath {
    const run = addRunGenerator(b, buildvm);
    run.setName(b.fmt("buildvm -m {s}", .{abi.vmMode(target)}));
    run.addArg("-m");
    run.addArg(abi.vmMode(target));
    run.addArg("-o");
    return run.addOutputFileArg2(switch (target.vm_output) {
        .pe_obj => "lj_vm.obj",
        else => "lj_vm.S",
    }, .{});
}

/// The six files `buildvm` writes by scanning the library sources.
const BuildvmOutputs = struct {
    /// The directory the five headers are written into, for the include path.
    generated_dir: std.Build.LazyPath,
    /// `jit/vmdef.lua`, which is also installed.
    vmdef: std.Build.LazyPath,
};

fn addBuildvmOutputs(
    b: *std.Build,
    buildvm: *std.Build.Step.Compile,
    version_header: std.Build.LazyPath,
) BuildvmOutputs {
    const dir = b.addWriteFiles();
    _ = dir.addCopyFile(version_header, "luajit.h");

    // One run step per mode, so no two modes' outputs collide and each is
    // separately cached. `fold` records `src/Makefile:709-711`'s different
    // argument list; the rest share `$(LJLIB_C)` (`src/Makefile:515`).
    const Scan = struct { mode: []const u8, output: []const u8, fold: bool };
    const scans = [_]Scan{
        .{ .mode = "bcdef", .output = "lj_bcdef.h", .fold = false },
        .{ .mode = "ffdef", .output = "lj_ffdef.h", .fold = false },
        .{ .mode = "libdef", .output = "lj_libdef.h", .fold = false },
        .{ .mode = "recdef", .output = "lj_recdef.h", .fold = false },
        .{ .mode = "vmdef", .output = sources.generated_vmdef_lua, .fold = false },
        .{ .mode = "folddef", .output = "lj_folddef.h", .fold = true },
    };

    var vmdef: std.Build.LazyPath = undefined;
    for (scans) |scan| {
        const run = addRunGenerator(b, buildvm);
        run.setName(b.fmt("buildvm -m {s}", .{scan.mode}));
        run.addArg("-m");
        run.addArg(scan.mode);
        run.addArg("-o");
        const out = run.addOutputFileArg2(scan.output, .{});
        if (scan.fold) {
            // `src/Makefile:711`: `buildvm -m folddef -o $@ lj_opt_fold.c`.
            run.addFileArg2(b.path(b.pathJoin(&.{ "src", "lj_opt_fold.c" })), .{});
        } else {
            // `src/Makefile:689-707`: the same `$(LJLIB_C)` list every mode
            // scans. `src/host/buildvm_lib.c:362-368` opens each by `fopen`, so
            // the paths must be the ones this build knows.
            for (sources.ljl_sources) |s| run.addFileArg2(b.path(b.pathJoin(&.{ "src", s })), .{});
        }
        if (std.mem.eql(u8, scan.mode, "vmdef")) {
            vmdef = out;
        } else {
            _ = dir.addCopyFile(out, scan.output);
        }
    }
    return .{ .generated_dir = dir.getDirectory(), .vmdef = vmdef };
}

/// Compile the library for the target.
fn addLibrary(
    b: *std.Build,
    o: Options,
    target: abi.Selection,
    defs: BuildvmOutputs,
    vm: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        // `src/Makefile:38`: `-O2 -fomit-frame-pointer`. The `-O2` half is the
        // caller's optimize mode; the frame-pointer half is pinned here,
        // because `src/Makefile:11-13` gives the reason: the assembler part does
        // not maintain a frame pointer, so the C part gains nothing from one.
        .omit_frame_pointer = true,
        // `src/Makefile:317-319`: `-fno-stack-protector` where the compiler
        // accepts it.
        .stack_protector = false,
    });
    mod.addIncludePath(b.path("src"));
    // Every generated header is included by bare name -- `lj_bcdef.h`,
    // `lj_ffdef.h`, `lj_libdef.h`, `lj_recdef.h`, `lj_folddef.h` and `luajit.h`
    // -- so the generated directories are on the compile line, not merely passed
    // as explicit inputs.
    mod.addIncludePath(defs.generated_dir);
    mod.addIncludePath(vm.dirname());
    mod.addIncludePath(b.path("src/host"));

    applyTargetArchMacros(mod, target, b);
    applyInstallRootMacros(mod, b, o.lua_root);

    // `src/Makefile:225-227`: `-D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE` and
    // `-U_FORTIFY_SOURCE`. Large-file support is what makes `off_t` 64-bit on the
    // 32-bit targets, x86 and arm both being 32-bit.
    mod.addCMacro("_FILE_OFFSET_BITS", "64");
    mod.addCMacro("_LARGEFILE_SOURCE", "1");
    mod.addCMacro("__STDC_CONSTANT_MACROS", "1");
    // `src/Makefile:325`: `-DLUAJIT_UNWIND_EXTERNAL` on Darwin, and `:343` when
    // the target toolchain always emits unwind tables, which is the ELF case for
    // every toolchain this build uses. It selects `LJ_UNWIND_EXT`
    // (`lj_arch.h:717-721`), which is how a traceback crosses a C call.
    if (target.os == .linux or target.os == .osx or target.os == .bsd or target.os == .posix) {
        mod.addCMacro("LUAJIT_UNWIND_EXTERNAL", "");
    }
    if (needsDllMacro(target, o.linkage)) mod.addCMacro("LUA_BUILD_AS_DLL", "");

    // `src/Makefile:228`: `-lm`, always. `src/Makefile:352-359`: `-ldl` on
    // Linux, GNU and Hurd, which is what `lib_ffi.c` and `lib_package.c` open C
    // modules through.
    mod.linkSystemLibrary("m", .{});
    switch (o.target.result.os.tag) {
        // Android carries `Os.Tag.linux` with an Android ABI
        // (`std/Target.zig:775-776`), so `.linux` already covers it; there
        // is no `.android` OS tag to write.
        .linux, .hurd => mod.linkSystemLibrary("dl", .{}),
        else => {},
    }

    // The upstream GCC driver supplies the external unwinder implicitly.
    // Zig links C objects without that driver, so ELF consumers need the
    // same public _Unwind_* and frame-registration ABI explicitly.
    switch (o.target.result.os.tag) {
        .linux, .hurd, .freebsd, .netbsd, .openbsd, .dragonfly => mod.linkSystemLibrary("gcc_s", .{ .use_pkg_config = .no }),
        else => {},
    }

    // `src/Makefile:517-530` (`$(LJCORE_O)`, `lib_init.c` appended at `:530`).
    //
    // The pinned C is written for upstream's compiler flags, not for Zig's
    // Debug C sanitizer: `src/lj_buf.c:298` shifts a promoted signed byte into
    // bit 31, and `src/lib_jit.c:747` reads a `uint32_t` at an unaligned
    // address. Both are deliberate upstream bit-level accesses, and the C
    // sanitizer is what turns them into traps. Turning it off is the same
    // argument lmdb, spglib and inchi already record, and it leaves Zig's own
    // sanitizer and every other optimization mode untouched.
    mod.sanitize_c = .off;
    for (sources.ljcore_sources) |s| mod.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ "src", s })) });
    mod.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ "src", sources.lib_init_source })) });
    // `src/Makefile:512-514` (`$(LJLIB_O)`).
    for (sources.ljl_sources) |s| mod.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ "src", s })) });
    // `src/Makefile:532` (`$(LJVMCORE_O)`) begins with the VM, which is not a C
    // source: `src/Makefile:507-510` assembles `lj_vm.S` for ELF and Mach-O, or
    // `:561` links the PE object `buildvm` wrote.
    switch (target.vm_output) {
        .pe_obj => mod.addObjectFile(vm),
        else => mod.addAssemblyFile(vm),
    }

    return b.addLibrary(.{
        .name = o.name_prefix,
        .linkage = o.linkage,
        .version = libraryVersion(b, o.release_version),
        .root_module = mod,
    });
}

/// The install-root macros, `src/Makefile:288-304`.
///
/// `-DLUA_ROOT` is the prefix `LUA_PATH_DEFAULT` searches (`luaconf.h:40-50`)
/// and `-DLUA_LJDIR` the `jit` module directory (`luaconf.h:52-56`). Upstream
/// quotes both on its command line, so both are quoted here; a C string macro
/// whose value is not quoted is a compile error.
///
/// Upstream guards the whole block on `PREFIX` being non-empty
/// (`src/Makefile:288-295`), which is the same condition as having an install
/// prefix to name.
fn applyInstallRootMacros(m: *std.Build.Module, b: *std.Build, lua_root: ?[]const u8) void {
    const root = lua_root orelse return;
    m.addCMacro("LUA_ROOT", b.dupe(b.fmt("\"{s}\"", .{root})));
    // `src/Makefile:297`: `MULTILIB`, from `Makefile:34`.
    m.addCMacro("LUA_MULTILIB", b.dupe("\"lib\""));
    // `src/Makefile:303`, with `INSTALL_LJLIBD= $(INSTALL_SHARE_)/luajit-$(MMVERSION)`
    // (`Makefile:45`).
    m.addCMacro("LUA_LJDIR", b.dupe(b.fmt(
        "\"{s}/share/luajit-{s}\"",
        .{ root, mm_version },
    )));
}

/// Compile the `luajit` CLI, linked against the library.
fn addCli(
    b: *std.Build,
    o: Options,
    target: abi.Selection,
    library: *std.Build.Step.Compile,
    defs: BuildvmOutputs,
    /// Which search path this copy of the CLI carries. `addGraph` compiles the
    /// program twice when the two differ; see `Loader`.
    loader: Loader,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        .omit_frame_pointer = true,
        .stack_protector = false,
    });
    mod.addIncludePath(b.path("src"));
    mod.addIncludePath(defs.generated_dir);
    applyTargetArchMacros(mod, target, b);
    applyInstallRootMacros(mod, b, o.lua_root);
    // `src/Makefile:573` adds `-DLUA_BUILD_AS_DLL` for the whole Windows build,
    // which makes the CLI a DLL *consumer*: `luaconf.h:132-133` expands `LUA_API`
    // to `__declspec(dllimport)` because the CLI defines neither `LUA_CORE` nor
    // `LUA_LIB`.
    if (needsDllMacro(target, o.linkage)) mod.addCMacro("LUA_BUILD_AS_DLL", "");
    mod.linkSystemLibrary("m", .{});
    switch (o.target.result.os.tag) {
        // Android carries `Os.Tag.linux` with an Android ABI
        // (`std/Target.zig:775-776`), so `.linux` already covers it; there
        // is no `.android` OS tag to write.
        .linux, .hurd => mod.linkSystemLibrary("dl", .{}),
        else => {},
    }
    // `src/Makefile:538`, `$(LUAJIT_O)`, built by `:727-729` with
    // `$(TARGET_STCC)` alone -- never the dynamic-flavoured compile -- so this
    // unit is separate from the library's.
    mod.addCSourceFile(.{ .file = b.path(b.pathJoin(&.{ "src", sources.front_end })) });
    // The installed CLI is `bin/luajit` and the installed library is
    // `lib/libluajit-5.1.so`, so the installed copy needs the install tree's own
    // search path to find it, while the copy `native-test` executes runs out of
    // the build cache with no `lib/` beside it. One description of the program
    // and one `Loader` argument decide which is which. See `linkForLoader`.
    linkForLoader(mod, library, o.target, loader);
    return b.addExecutable(.{
        .name = if (loader == .build_cache) b.fmt("{s}-cache-run", .{o.name_prefix}) else o.name_prefix,
        .root_module = mod,
    });
}

/// Where a program built against this SDK's shared library must find it.
///
/// The two are not two spellings of one answer, and one program cannot carry
/// both: `Module.linkLibrary` records the directory the shared object was emitted
/// into, because `Step.Compile` appends `-rpath <dir>` for every dynamic
/// artifact a compilation links (`lib/std/Build/Step/Compile.zig:1290-1297`,
/// the block reached from `.other_step`).  That directory is the build cache.
/// It does not exist once the file is installed, and Nix refuses an installed
/// file that names its own build directory at all, so an installed program
/// that carried it could never be packaged -- and on ELF the loader would
/// search a directory that is gone rather than the one that is there.
/// `Module.addObjectFile` puts the very same file on the link line and records
/// no search path at all, which leaves the relocatable entry
/// `installedProgramRPath` returns as the only one an installed artifact
/// carries.
///
/// Which of the two a program gets is a property of where it will run. A
/// program built from the published `luajit` module is built in some build
/// cache -- a dependent's own, or this build's -- and the entry a module
/// contributes lands on every compilation whose graph imports it, so that
/// module is `build_cache`. Only an installed program is `install_tree`, and
/// the one this package installs is the CLI, which links the library through a
/// module of its own rather than through the facade.
pub const Loader = enum {
    /// A program `zig build install` writes into `bin/`.  It carries
    /// `$ORIGIN/../lib` -- `@loader_path/../lib` on Mach-O -- and nothing else,
    /// so it finds the library this prefix installed beside it and still finds
    /// it after the tree is moved.
    install_tree,
    /// Everything that is not installed, the published facade included: a
    /// dependent's executable, the copy of the CLI `native-test` drives, the
    /// test binary and the smoke example.  It keeps the ordinary
    /// `linkLibrary` call, so Zig bakes in the directory the library really is
    /// in and the loader looks there.  The entry never reaches a store,
    /// because nothing built this way is ever installed.
    build_cache,
};

/// Put `library` on `module`'s link line, with the search path a program of
/// this `Loader` needs and nothing else.
fn linkForLoader(
    module: *std.Build.Module,
    library: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    loader: Loader,
) void {
    // Windows links through the import library and has no rpath, so the
    // ordinary call is the right one there for both loaders and is kept.
    if (library.linkage != .dynamic or target.result.os.tag == .windows) {
        module.linkLibrary(library);
        return;
    }
    switch (loader) {
        .build_cache => module.linkLibrary(library),
        .install_tree => {
            module.addObjectFile(library.getEmittedBin());
            if (installedProgramRPath(target)) |rpath| module.addRPathSpecial(rpath);
        },
    }
}

/// Whether a target's programs have to be compiled twice to have both loaders.
///
/// A static archive, an import-library link on COFF and a runtime-loading
/// graph all produce the same file for both `Loader` values, so a second copy
/// would be a second copy of a binary that is already right.  A shared library
/// on a platform with a runpath is the one case where they differ, and it is
/// the only case that pays for the second compilation.
fn needsBothLoaders(
    linked: ?*std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) bool {
    const library = linked orelse return false;
    return library.linkage == .dynamic and target.result.os.tag != .windows;
}

/// The runtime search path an installed program needs so that its loader
/// finds the shared object this same prefix installed beside it.
///
/// `bin/luajit` and `lib/libluajit-5.1.so` are siblings under one prefix, so
/// `$ORIGIN/../lib` is the ELF spelling and `@loader_path/../lib` the Mach-O
/// one, and both name this install tree and no other.  COFF has neither:
/// upstream installs `lua51.dll` into `bin/` beside the CLI
/// (`src/Makefile:55`), which is where its loader looks first.  A target with
/// no dynamic loader has nothing to name either.
pub fn installedProgramRPath(target: std.Build.ResolvedTarget) ?[]const u8 {
    return switch (target.result.os.tag) {
        .windows, .wasi, .uefi => null,
        else => if (target.result.os.tag.isDarwin()) "@loader_path/../lib" else "$ORIGIN/../lib",
    };
}

/// The translation of the public headers.
///
/// `build_support/translate.h` is the aggregate; it is read through
/// `zig translate-c`, which parses with Aro and preprocesses for itself.
///
/// The routes exist because Aro is not the preprocessor this repository's C is
/// compiled by, and on some C libraries the two disagree about the same header.
/// `routeFor` picks per target and `preprocessedAggregate` is the extra front
/// end; both read this repository's headers on the same include path with the
/// same macros, so only the preprocessor that has to understand the target's C
/// library changes.
fn addTranslate(
    b: *std.Build,
    o: Options,
    target: abi.Selection,
    version_header: std.Build.LazyPath,
    defs: BuildvmOutputs,
) *std.Build.Step.TranslateC {
    const generated_dirs = [_]std.Build.LazyPath{ version_header.dirname(), defs.generated_dir };
    const aggregate = switch (routeFor(o.target)) {
        .aro => b.path("build_support/translate.h"),
        .preprocessed => preprocessedAggregate(b, o, target, &generated_dirs),
    };

    const translate = b.addTranslateC(.{
        .root_source_file = aggregate,
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
    });
    translate.addIncludePath(b.path("src"));
    translate.addIncludePath(b.path("src/host"));
    // The generated headers are read by bare name, so their directories are on
    // the translation line as well as the compile line. `luajit.h` in
    // particular is the generated one: `luajit_rolling.h:79` ends in `#error`, so
    // translating it would be translating a deliberate refusal.
    for (generated_dirs) |d| translate.addIncludePath(d);
    // The same macros as the compile line, so the declarations describe the
    // archive that was built rather than a second revision of it.
    for (abi.targetArchMacros(target, b.allocator)) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=')) |i| {
            translate.defineCMacro(entry[0..i], entry[i + 1 ..]);
        } else {
            translate.defineCMacro(entry, "");
        }
    }
    translate.defineCMacro("_FILE_OFFSET_BITS", "64");
    translate.defineCMacro("_LARGEFILE_SOURCE", "1");
    // `luaconf.h:40-56` resolves `LUA_PATH_DEFAULT` and `LUA_LJDIR` from these
    // three, so a translation that omitted them would carry the defaults while
    // the archive was compiled against the install root.
    if (o.lua_root) |root| {
        translate.defineCMacro("LUA_ROOT", b.fmt("\"{s}\"", .{root}));
        translate.defineCMacro("LUA_MULTILIB", "\"lib\"");
        translate.defineCMacro("LUA_LJDIR", b.fmt(
            "\"{s}/share/luajit-{s}\"",
            .{ root, mm_version },
        ));
    }
    if (needsDllMacro(target, o.linkage)) translate.defineCMacro("LUA_BUILD_AS_DLL", "");
    return translate;
}

/// Which front end reads `build_support/translate.h` for one target.
pub const AggregateRoute = enum {
    /// Aro preprocesses the aggregate for itself and parses what comes out.
    aro,
    /// The target's own C preprocessor expands it first, and Aro parses that.
    preprocessed,
};

/// Chooses the front end.
///
/// ## Aro, where the target's C library is GNU libc
///
/// Aro preprocesses as well as parses, so it can do both jobs itself. The
/// headers this aggregate pulls in are small -- `luaconf.h:12` and
/// `lauxlib.h:12-13` include `<stddef.h>`, `<stdio.h>` and `<assert.h>`, and
/// `lua.h:12-13` `<stdarg.h>` and `<stddef.h>`, and nothing else reaches a
/// system header -- so the drag-in is the fixed C headers of a glibc target.
///
/// ## The target's own preprocessor on every other target
///
/// Aro's copy of a C library is not always the one the target's compiler reads.
/// The PCRE2 fork in this workspace observed Aro failing on NetBSD's
/// `sys/cdefs.h`, on OpenBSD's `endian.h`, and on Windows-x86's `malloc.h`,
/// each because of a macro that header guards on a predefine Aro's table does
/// not carry; its notes record the reasoning
/// (`pcre2/build.zig:676-682`, and the `aggregateRoute` comment above
/// `:713`). LuaJIT's own header set is smaller than PCRE2's, but the boundary is
/// the same one, and it is not this file's to close by inventing a predefine:
/// those macros decide what the C library headers mean, so faking one would
/// describe a target that does not exist.
///
/// Running the compiler that also compiles the C core, for the target the core
/// is compiled for, on the same include path, is not a substitute for any of
/// those: the target, the include path, the widths and the macros are the ones
/// the archive was built with, so the declarations the translator reads are the
/// ones that archive answers to.
pub fn routeFor(target: std.Build.ResolvedTarget) AggregateRoute {
    return if (target.result.isGnuLibC()) .aro else .preprocessed;
}

/// `build_support/translate.h`, preprocessed for the target being built.
///
/// The front end is `b.graph.zig_exe cc`, which is the compiler running this
/// build script, so the target, the include path and the widths are the ones the
/// C core is compiled with. `-dD` keeps the `#define` lines beside the expanded
/// text, so a macro a C caller reads as a macro still reaches Zig as a constant:
/// `luaconf.h` is almost entirely macros, and the facade names several of them.
///
/// `-fno-blocks` keeps the two front ends in one dialect. Aro has no block
/// pointers, Clang's driver enables the blocks extension by default for a Darwin
/// target, and the Darwin C library then declares six entry points that take a
/// block pointer, which Aro cannot parse. It takes nothing from LuaJIT: none of
/// the headers in this aggregate names a block type, so what leaves the file is
/// declarations of the target's C library that the translator could never have
/// held anyway.
fn preprocessedAggregate(
    b: *std.Build,
    o: Options,
    target: abi.Selection,
    generated_dirs: []const std.Build.LazyPath,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&[_][]const u8{
        b.graph.zig_exe, "cc", "-E", "-dD", "-fno-blocks", "-x", "c",
    });
    run.setName("preprocess luajit public headers");
    if (!o.target.query.isNative()) {
        const triple = o.target.query.zigTriple(b.allocator) catch @panic("luajit: unspellable target");
        run.addArg("-target");
        run.addArg(triple);
    }
    // `src/`, for the headers themselves, then each generated directory.
    run.addDirectoryArg2(b.path("src"), .{ .prefix = "-I" });
    for (generated_dirs) |d| run.addDirectoryArg2(d, .{ .prefix = "-I" });
    for (abi.targetArchMacros(target, b.allocator)) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '=')) |i| {
            run.addArg(b.fmt("-D{s}={s}", .{ entry[0..i], entry[i + 1 ..] }));
        } else {
            run.addArg(b.fmt("-D{s}", .{entry}));
        }
    }
    if (o.lua_root) |root| {
        run.addArg(b.fmt("-DLUA_ROOT=\"{s}\"", .{root}));
        run.addArg("-DLUA_MULTILIB=\"lib\"");
        run.addArg(b.fmt("-DLUA_LJDIR=\"{s}/share/luajit-{s}\"", .{ root, mm_version }));
    }
    if (needsDllMacro(target, o.linkage)) run.addArg("-DLUA_BUILD_AS_DLL");
    // Aro parses this file, and `-dD` keeps every `#define` in it as a macro
    // Aro turns into a Zig constant -- `luaconf.h` is mostly macros and the
    // facade names several of them. Some target C libraries name `__int128_t`
    // in a macro body without any header declaring the type: NetBSD's
    // `generic-netbsd/arm/cdefs.h:62-63` uses it, and on aarch64 the macro that
    // reaches Aro then reads `__helpers.sizeof(__int128_t)` for a type name
    // Aro has never been told about, and the translated module fails with
    // `use of undeclared identifier '__int128_t'`.
    //
    // `__int128_t` is a *compiler* spelling -- `__SIZEOF_INT128__` is what the
    // compiler itself defines -- so the completion is a typedef of that
    // builtin, pulled in through the target's own preprocessor and guarded by
    // the predefine the compiler emits, with `!defined(__int128_t)` leaving the
    // name alone where a C library has already spelled it another way. It
    // declares no platform and pretends no compiler identity: the same
    // completion ERFA's translation aggregate carries for its NetBSD cells.
    const shim = b.addWriteFiles().add("int128.h",
        \\#if defined(__SIZEOF_INT128__) && !defined(__int128_t)
        \\typedef __int128 __int128_t;
        \\typedef unsigned __int128 __uint128_t;
        \\#endif
        \\
    );
    // `-include` is processed before the translation unit's own first include,
    // so the typedefs are in scope for every system header that follows.
    run.addFileArg2(shim, .{ .prefix = "-include" });
    run.addArg("-o");
    // The generated file is this step's output, so the step is cached: a second
    // build with the same inputs neither re-runs the preprocessor nor rewrites
    // the file.
    const preprocessed = run.addOutputFileArg2("luajit_translate.h", .{});
    run.addFileArg2(b.path("build_support/translate.h"), .{});
    return preprocessed;
}
