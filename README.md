# luajit

A Zig 0.17.0 package for LuaJIT 2.1.1788856981, pinned to
`c6ffc141a8762b41703f9287d63d93622a13dd8f`.
It builds upstream C sources and exports a typed Zig facade plus the translated C API.

## Source deviations from upstream

Upstream's `src/`, `dynasm/`, `doc/`, `etc/`, `COPYRIGHT`, Makefiles,
`.relver` and `.gitattributes` are unchanged. The root `.gitignore` keeps
upstream's patterns and appends fork rules. `README.upstream.md` is the upstream
README copy; this file is fork-authored. `UPSTREAM.sha256` records the unchanged
upstream files. `UPSTREAM.md` identifies the pin and generated version.

## Build deviations

`build.zig` replaces the upstream Makefiles. It compiles the upstream object
closure without downloading sources. It omits `ljamalg.c`, which includes the
same sources and would duplicate symbols.

The upstream `buildvm` and `minilua` tools are compiled and run on the build
host. They generate target-specific VM code and VM headers. `luajit.h` is
generated from `.relver`. The upstream `minilua.c` amalgamation and
`buildvm_libbc.h` output are checked in: regenerating them requires an absent
Lua 5.1.5 source tree, and `buildvm_libbc.h` also requires a built LuaJIT.

`zig build install` installs the library, six public headers, nineteen JIT
modules (including generated `vmdef.lua`), CLI, manual, `luajit.pc`, upstream
copyright text and fork provenance/licence records.

## Support matrix

| Target family | Source status |
|---|---|
| x86, x86_64; ARM/Thumb; AArch64; big-endian PowerPC32; MIPS32 and MIPS64 | Included in upstream's architecture selector. |
| PowerPC64, RISC-V, wasm32/WASI, other unlisted architectures | Refused by upstream. |

Upstream also refuses big-endian ARM, Cortex-M and little-endian PowerPC32.
Its Windows PE emitter has no 32-bit Thumb output. Some MIPS64 toolchains
reject upstream's `__clear_cache` call because they do not declare it.

The build selects PE/COFF output for Windows, Mach-O assembly for Darwin-family
targets and ELF assembly otherwise. Architecture and toolchain constraints
still apply.

## Consumption

The package is local and unpublished. Point a Zig package at a checkout in
`build.zig.zon`:

```zig
.dependencies = .{
    .luajit = .{ .path = "../luajit" },
},
```

In `build.zig`, import `dep.module("luajit")` under the name `luajit`;
source files use `@import("luajit")`. The module's `c` declaration is the raw
translated API (`luajit.c`).

| Name | Value |
|---|---|
| Zig module | `luajit` |
| Native library base | `luajit-5.1` |
| Static artifact | `lib/libluajit-5.1.a` |
| Shared ELF artifacts | `libluajit-5.1.so.2.1.1788856981`, `.so.2` and `.so` symlinks |
| Shared Darwin artifacts | `libluajit-5.1.2.1.1788856981.dylib`, `libluajit-5.1.2.dylib`, `libluajit-5.1.dylib` |
| Shared Windows artifacts | `luajit-5.1.dll` and import library `luajit-5.1.lib` |
| Link name | `-lluajit-5.1` |
| pkg-config | `luajit.pc`, module name `luajit`; `--static` adds `-lgcc_s` on ELF Unix |
| Header directory | `include/luajit-2.1` |

| Option | Values | Default and effect |
|---|---|---|
| `-Dtarget` / `-Dcpu` | Zig target query | `-Dtarget` defaults to the host; Zig resolves the CPU unless selected. |
| `-Doptimize` | `debug`, `safe`, `fast`, `small` | Zig default; applies to native and Zig code. |
| `-Dlinkage` | `static`, `dynamic` | `static`; selects the installed native artifact. |
| `-Druntime` | `true`, `false` | `false`; resolves native calls through the platform loader instead of linking the archive into the facade. Orthogonal to `linkage`; the library remains built and installed as provider. |
| `-Dlua-root` | absolute path | Optional install root compiled into the library and CLI. Relative paths are refused. When omitted, upstream's distribution layout applies; the root is no longer inferred from `--prefix`. |