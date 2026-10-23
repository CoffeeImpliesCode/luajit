# Fork notes

## Source deviations

| File | Change and reason |
|---|---|
| `.gitignore` | Keeps upstream patterns and adds Zig cache and install paths so generated build output stays out of the source tree. |

No imported C, assembly, header, data, or licence file is modified. Files under `src/`, `dynasm/`, `doc/`, and `etc/`, plus `COPYRIGHT`, `Makefile`, `.relver`, and `.gitattributes`, remain upstream's.

## Build graph

- `build.zig` and `build_support/sources.zig` replace upstream's Make build with Zig steps for the same 69 C units and assembled VM object. `ljamalg.c` is omitted because it includes those sources again.
- `build_support/graph.zig` builds the host tools and runs DynASM, `buildvm`, and `genversion.lua` on the build host to produce target-specific inputs. It uses upstream's checked-in `src/host/minilua.c` and `src/host/buildvm_libbc.h`; their source generators require an absent Lua 5.1.5 tree.
- `build_support/abi.zig` maps Zig target features to LuaJIT and DynASM macros, including MIPS endianness and R6 mode. It maps Catalyst as both Darwin and iOS for the relevant assembler and library flags.
- The 32-bit generator must have the target's pointer width. The graph builds a 32-bit host generator when needed; that program still has to run on the build host or through its configured executor.
- Narrowed Linux generators use Zig's automatic run executor; Zig 0.17 does not let the build script force QEMU when it considers a 32-bit target CPU-compatible with the host.
- `.relver` supplies the rolling release timestamp used by the generated version header. The manifest, library names, and `luajit.pc` use that same version.
- `-Dlinkage` selects a static archive or shared library (static by default). `-Druntime` independently selects linked calls or runtime dispatch; the runtime facade does not link the archive, but the library is built and installed in either mode.
- `-Dlua-root` must be absolute and is embedded only when explicitly supplied. Zig 0.17 exposes the install prefix as a lazy path, not a configure-time string suitable for embedding it.
- The consumer build receives target, CPU, optimization, linkage, runtime, explicit root, lazy cache paths, and the parent prefix. Consumer installs use that prefix even by default because Zig 0.17 exposes no configure-time distinction between an explicit and default prefix.
- Nested builds use `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LIB_DIR`; Zig 0.17 rejects their CLI equivalents for `zig build`. `--build-file` selects the consumer without changing the working directory used by relative environment paths.
- The nested consumer build cannot forward the parent's `--libc-runtimes`, so GNU-libc QEMU targets are install-only.
- Consumer run/install selection checks native dynamic-loader availability and poisons the nested configuration cache because the filesystem check has no tracked input.
- The outer consumer run depends on package installation so the parent prefix exists before Zig 0.17 resolves it as an input directory.
- ELF Unix builds link `gcc_s` for LuaJIT's external unwinder, and static `luajit.pc` metadata adds the same dependency. Darwin omits the upstream `-Wl,-E` flag.
- The graph passes `-fno-sanitize=shift-base` to native C because upstream's ULEB128 decoder shifts a signed value into the sign bit; other sanitizer checks remain enabled.
- The runtime resolver accounts for fortified libc declarations in safe optimization mode so libc symbols are not mistaken for provider symbols.
- `zig build install` installs the CLI, selected library, public headers, JIT modules, man page, pkg-config file, copyright, and fork records. It omits upstream's versioned CLI symlink and empty module directories. Windows library filenames differ from upstream's, but the exported symbols and link name do not.
- `package.nix` refuses cross builds; the Zig build graph accepts explicit cross targets.

## Platform boundaries

- LuaJIT 2.1 supports x86, x64, ARM, ARM64, PowerPC, MIPS32, and MIPS64. `riscv64` and `wasm32-wasi` are outside that architecture set; the check graph expects upstream's configure-time refusal.
- Upstream's MIPS64 Linux and OpenBSD paths fail to compile where `lj_mcode.c` calls undeclared `__clear_cache`. N64 builds also report `-fno-PIC`; the graph does not add that flag.
- LuaJIT 2.1 has no PE object emitter for 32-bit ARM, so `thumb-windows` is unsupported by upstream.
- GC64 is fixed on for ARM64 and MIPS64, off for 32-bit targets, and on for x64 in this package. Upstream rejects disabling GC64 on macOS; GC64 variants are not ABI-interchangeable.
- ELF Unix uses the external unwinder dependency. Darwin, Windows, and WASI follow different linker or object-emission paths.
- The Nix derivation supports only matching build and host systems. Cross-compilation is available through the Zig build graph, not through `package.nix`.
