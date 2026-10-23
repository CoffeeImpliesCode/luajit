// SPDX-License-Identifier: MIT
//! LuaJIT's target architecture selection, as `src/lj_arch.h` and `src/Makefile`
//! define it.
//!
//! Upstream computes `TARGET_LJARCH` and the DynASM defines by running the
//! target compiler's preprocessor over `src/lj_arch.h` and reading the macro
//! dump (`src/Makefile:236`, `TARGET_TESTARCH`). This file computes the same
//! values from the resolved `std.Target`, because the DynASM command line has
//! to be fixed when the build graph is constructed and a Run step cannot feed
//! its output into another step's argument list.
//!
//! Two properties make the two routes agree.
//!
//! First, every value `lj_arch.h` would take from a compiler predefine that
//! this file cannot see is **pinned explicitly** on the C compile line, the way
//! `src/Makefile:285-287`, `:428-431` and `:432-437` already pin
//! `LUAJIT_TARGET`, `LJ_ARCH_HASFPU` and `LJ_ABI_SOFTFP`. `lj_arch.h` guards
//! every one of them with `#ifndef` (`lj_arch.h:52`, `:288`, `:222`, `:234`,
//! `:646-648`, `:649-651`, `:655-657`), so a pinned value wins and the C side
//! cannot disagree with the DynASM side. `LJ_ABI_PAUTH`, `LJ_ABI_BRANCH_TRACK`
//! and `LJ_ABI_SHADOW_STACK` are pinned here for the same reason; upstream
//! leaves them to the probe.
//!
//! Second, everything that genuinely comes from the target -- word size,
//! endianness, OS, FPU and soft-float ABI -- is read from `std.Target`, which
//! carries the same information the predefine would have. `LJ_ABI_PAUTH` is
//! the one capability `std.Target` cannot name, so the aarch64 branch states
//! separately what the compiler reports for every target this build can
//! produce and why. No value below is a default standing in for a decision:
//! each one names the `lj_arch.h` or `src/Makefile` line it reproduces.
//!
//! Nothing here reads the host. Every function is a function of `target`.

const std = @import("std");

/// The architecture names of `src/lj_arch.h:18-33`
/// (`LUAJIT_ARCH_<name>`), spelled the way `src/Makefile:286` spells them.
pub const Arch = enum {
    x86,
    x64,
    arm,
    arm64,
    ppc,
    mips,
    mips64,
};

/// The `LUAJIT_OS_*` constants of `src/lj_arch.h:36-42`.
pub const Os = enum {
    other,
    windows,
    linux,
    osx,
    bsd,
    posix,
};

/// Which `LJVM_MODE` output `buildvm` emits (`src/Makefile:507-510`, `:559-562`,
/// `:576-583`).
pub const VmOutput = enum {
    /// `src/Makefile:510`: the default for every target that is not Darwin,
    /// iOS or Windows. `buildvm -m elfasm` writes a `.S` file that the target C
    /// compiler assembles.
    elf_asm,
    /// `src/Makefile:576-578`: Darwin. `buildvm -m machasm` writes Mach-O
    /// assembler, still a `.S` file.
    mach_asm,
    /// `src/Makefile:559-562`: Windows. `buildvm -m peobj` writes a PE/COFF
    /// object file directly, because upstream cannot assume an assembler is
    /// present, so this output is linked as an object and never assembled.
    pe_obj,
};

/// Everything the native graph needs about one target's ABI.
pub const Selection = struct {
    arch: Arch,
    /// `LUAJIT_OS_*`, the value `src/lj_arch.h:75-106` detects. It goes on the
    /// **host** compile line too when host and target OS differ, because
    /// `src/Makefile:364-382` does that: the generators run on the host but
    /// must emit code shaped for the target.
    os: Os,
    bits: u8,
    /// `LJ_ARCH_ENDIAN == LUAJIT_BE`, i.e. `LJ_BE` is 1 (`lj_arch.h:14-15`).
    big_endian: bool,
    /// `LJ_ARCH_HASFPU`, pinned (`lj_arch.h:646-648`).
    has_fpu: bool,
    /// `LJ_ABI_SOFTFP`, pinned (`lj_arch.h:649-651`).
    soft_fp: bool,
    /// `LJ_ABI_PAUTH`, pinned (`lj_arch.h:288-290`).
    pauth: bool,
    vm_output: VmOutput,
    /// The `vm_<arch>.dasc` `src/Makefile:489` names (`$(DASM_DASC)`).
    dasc_source: []const u8,
    /// `LJ_ARCH_VERSION` (`lj_arch.h:266-276`, `:311`, `:373-385`, `:470-476`).
    /// Null where `lj_arch.h` defines no `LJ_ARCH_VERSION` at all -- which is
    /// x86 and x64, so upstream's `-D VER=` (`src/Makefile:454`) has an empty
    /// right-hand side there -- and where `std.Target` carries no information
    /// equivalent, which is PowerPC: Zig's model set has no counterpart to the
    /// `_ARCH_PWR4`.._ARCH_PWR7` macros `lj_arch.h:373-385` tests.
    ///
    /// This value reaches generated code only through `-D VER=`, and no
    /// `vm_*.dasc` in this tree reads `VER` -- `grep -c VER` is 0 for all seven
    /// of them -- so the gap cannot change what this build produces. It is
    /// recorded rather than filled with an invented number.
    arch_version: ?u32,
};

/// Why a target cannot be built, in upstream's own terms.
pub const Unsupported = error{
    /// No branch of the chain at `lj_arch.h:54-70` names this CPU architecture,
    /// so `lj_arch.h:69` fires.
    ArchitectureNotSupported,
    /// `lj_arch.h:369-370`: `#error "No support for PPC64"`.
    Ppc64NotSupported,
};

/// The text `lj_arch.h:69` produces, without the quotes the `#error` syntax
/// adds. Reproduced so a failure names upstream's own statement.
pub const architecture_not_supported_message =
    "Architecture not supported (in this version), see: https://luajit.org/status.html#architectures";

/// Resolve one target's LuaJIT ABI selection.
pub fn select(t: std.Target) Unsupported!Selection {
    const os: Os = switch (t.os.tag) {
        .windows => .windows,
        // Android has no `Os.Tag` of its own: it is `linux` carrying an Android
        // *ABI* (`std/Target.zig:775-776` names `Abi.android` and
        // `Abi.androideabi`), which is also what `lj_arch.h:79-80` keys on
        // through `__linux__`. A `.android` case here does not exist.
        .linux => .linux,
        // Mac Catalyst is its own `Os.Tag` in Zig 0.17 (`std/Target.zig:42`)
        // and its own object format case (`:1057`, `.macho`), but it is
        // Darwin and iOS at the same time and upstream says so: Darwin takes
        // `-DLUAJIT_OS=LUAJIT_OS_OSX` (`src/Makefile:370-372`), iOS takes the
        // same value with `-DLUAJIT_TARGET_IPHONE=1` (`:373-376`), and
        // `lj_arch.h:81` reads `LUAJIT_OS_OSX` from `__MACH__ && __APPLE__`,
        // which Catalyst's own headers satisfy. It is the OS name that decides
        // the assembler `buildvm` writes (`vmOutput`, below) and the `LUAJIT_OS_*`
        // on the generator line (`osMacro`), and both are Mach-O. Leaving it in
        // `else` answered `Os.other`, which asked `buildvm` for ELF
        // (`src/host/buildvm_asm.c:195-232`) and put `LUAJIT_OS_OTHER` on a
        // Darwin generator's line.
        .macos, .ios, .maccatalyst, .tvos, .watchos, .visionos => .osx,
        .freebsd, .netbsd, .openbsd, .dragonfly => .bsd,
        // Zig represents Solaris-family targets as illumos.
        .illumos, .haiku, .hurd => .posix,
        else => .other,
    };

    return switch (t.cpu.arch) {
        // `lj_arch.h:56`: `__i386`/`__i386__`/`_M_IX86`.
        .x86 => .{
            .arch = .x86,
            .os = os,
            .bits = 32, // `lj_arch.h:191`.
            .big_endian = false, // `lj_arch.h:192`.
            .has_fpu = true, // `lj_arch.h:646-648` default.
            .soft_fp = false, // `lj_arch.h:649-651` default.
            .pauth = false,
            .vm_output = vmOutput(os),
            .dasc_source = "vm_x86.dasc",
            // No `LJ_ARCH_VERSION` in the x86 branch of `lj_arch.h:188-200`.
            .arch_version = null,
        },
        // `lj_arch.h:58`: `__x86_64__`/`__x86_64`/`_M_X64`/`_M_AMD64`.
        .x86_64 => .{
            .arch = .x64,
            .os = os,
            .bits = 64, // `lj_arch.h:202`.
            .big_endian = false, // `lj_arch.h:206`.
            .has_fpu = true,
            .soft_fp = false,
            .pauth = false,
            .vm_output = vmOutput(os),
            .dasc_source = "vm_x64.dasc",
            // No `LJ_ARCH_VERSION` in the x64 branch, `lj_arch.h:202-243`.
            .arch_version = null,
        },
        // `lj_arch.h:60-61`: `__arm__`/`__arm`/`__ARM__`/`__ARM`. Zig has no
        // `.arm_thumb`; the Thumb instruction set is its own `Cpu.Arch`
        // (`.thumb`, `.thumbeb`), and the little-endian form is the one
        // `lj_arch.h:249` names `LUAJIT_LE`. The big-endian pair is left to the
        // `#else` below, because `lj_arch.h:528-531` refuses big-endian ARM.
        .arm, .thumb => .{
            .arch = .arm,
            .os = os,
            .bits = 32, // `lj_arch.h:247`.
            .big_endian = false, // `lj_arch.h:249`.
            // `lj_arch.h:250-252` clears `LJ_ARCH_HASFPU` only under
            // `__SOFTFP__`, which Zig reports as the `soft_float` feature.
            // `lj_arch.h:527-539` refuses big-endian ARM and the Cortex-M cores
            // outright; those refusals belong to the compiler and this file
            // does not pre-empt them.
            .has_fpu = !std.Target.arm.featureSetHas(t.cpu.features, .soft_float),
            // `lj_arch.h:253-255`: soft-float ABI when `__ARM_PCS_VFP` is
            // absent, i.e. when the target has neither VFP nor NEON.
            .soft_fp = !std.Target.arm.featureSetHas(t.cpu.features, .vfp4) and
                !std.Target.arm.featureSetHas(t.cpu.features, .neon),
            .pauth = false,
            .vm_output = vmOutput(os),
            .dasc_source = "vm_arm.dasc",
            .arch_version = armArchVersion(t),
        },
        // `lj_arch.h:62`: `__aarch64__`/`_M_ARM64`, and `aarch64_be` for the
        // big-endian variant of the same branch.
        .aarch64, .aarch64_be => .{
            .arch = .arm64,
            .os = os,
            .bits = 64, // `lj_arch.h:279`.
            // `lj_arch.h:281-287`: `__AARCH64EB__` selects the `arm64be` name
            // and `LUAJIT_BE`. The same macro is pinned on the compile line by
            // `targetArchMacros`, so the two sides agree.
            .big_endian = t.cpu.arch == .aarch64_be,
            .has_fpu = true,
            .soft_fp = false,
            // `lj_arch.h:288-290` turns pointer authentication on from the
            // compiler's own `__arm64e__`. `src/Makefile:236` reads that out of
            // `$(TARGET_CC) -E lj_arch.h -dM` and `src/Makefile:442-445` turns
            // it into `-DLJ_ABI_PAUTH=1` plus DynASM `-D PAUTH`. The macro
            // belongs to the arm64e *ABI* -- clang defines it for
            // `-target arm64e-apple-macos` -- and `std.Target` cannot name
            // that ABI: there is no arm64e `std.Target.Abi`, no arm64e CPU
            // model, and the model an `aarch64`/`macos` query resolves to is
            // `apple_m1` (`lib/std/Target.zig:2022-2023`), an ordinary arm64
            // core. No target this build can produce predefines `__arm64e__`,
            // so the compiler reports 0 for every one of them and 0 is what is
            // pinned here; the C side then takes `lj_obj.h:1104-1106`, exactly
            // as an upstream `clang -arch arm64` build does.
            //
            // This is the compiler's answer, not a switch turned off to get a
            // compile through. A pauth build is more than the define:
            // `src/vm_arm64.dasc:83-87` emits the real `braaz`/`blraaz` PAC
            // branches and `src/lj_target_arm64.h:332-333` switches the
            // assembler aliases to match, so signing needs a toolchain that
            // implements the intrinsics -- and Zig's own
            // `lib/include/ptrauth.h:315-393` only supplies no-op fallbacks
            // while `ptrauth_intrinsics` is off, which would drop the signing
            // those branches depend on. Reading the capability off the CPU
            // model name was also self-contradictory: the same architecture
            // with `-Dcpu=generic` names no `apple_*` model and would have
            // been built the other way round.
            .pauth = false,
            .vm_output = vmOutput(os),
            .dasc_source = "vm_arm64.dasc",
            .arch_version = 80, // `lj_arch.h:311`.
        },
        // `lj_arch.h:64`: the `__ppc__` family.
        .powerpc => .{
            .arch = .ppc,
            .os = os,
            .bits = 32, // `lj_arch.h:324-327`, the `_LP64` false case.
            // `lj_arch.h:317-321`: little-endian PPC. `lj_arch.h:546-549`
            // refuses little-endian PPC32, so only the big-endian form is ever
            // selected, and `targetArchMacros` pins `-DLJ_ARCH_ENDIAN=LUAJIT_BE`.
            .big_endian = true,
            .has_fpu = std.Target.powerpc.featureSetHas(t.cpu.features, .hard_float), // `lj_arch.h:334-341`.
            .soft_fp = !std.Target.powerpc.featureSetHas(t.cpu.features, .hard_float), // `lj_arch.h:342-348`.
            .pauth = false,
            .vm_output = vmOutput(os),
            .dasc_source = "vm_ppc.dasc",
            // `lj_arch.h:373-385` reads `_ARCH_PWR4`.._ARCH_PWR7, which
            // `std.Target.powerpc` does not model; see `Selection.arch_version`.
            .arch_version = null,
        },
        // `lj_arch.h:365-370`: `#error "No support for PPC64"`.
        .powerpc64 => return error.Ppc64NotSupported,
        // `lj_arch.h:66`: `__mips64__`/`__mips64`/`__MIPS64__`/`__MIPS64`.
        // Zig spells the little-endian form as its own `Cpu.Arch`, `.mips64el`,
        // and `lj_arch.h:401-405` supports it through `__MIPSEL__`, so both
        // are accepted here rather than falling to the unsupported `#else`.
        .mips64, .mips64el => .{
            .arch = .mips64,
            .os = os,
            .bits = 64, // `lj_arch.h:456-459`.
            // `lj_arch.h:434` is `LUAJIT_BE` when `__MIPSEL__` is absent and
            // `:419` is `LUAJIT_LE` when `targetArchMacros` pins it, so this
            // field has to carry the same answer: `.mips64` is the big-endian
            // `Cpu.Arch` and `.mips64el` the little-endian one
            // (`std/Target.zig:1663-1664`, `:1691-1692`), and `big_endian` is
            // what `abi.zig:83-84` says it means. Both consumers read this one
            // field -- `targetArchMacros` for `-D__MIPSEL__=1` and
            // `dynasmDefines` for `-D ENDIAN_BE`/`-D ENDIAN_LE` -- so a value
            // that disagreed with its own name would give DynASM the opposite
            // endianness from `lj_arch.h` and lay the VM out wrong.
            .big_endian = t.cpu.arch.endian() == .big,
            .has_fpu = !std.Target.mips.featureSetHas(t.cpu.features, .soft_float), // `lj_arch.h:437-443`.
            .soft_fp = std.Target.mips.featureSetHas(t.cpu.features, .soft_float), // `lj_arch.h:445-451`.
            .pauth = false,
            .vm_output = vmOutput(os),
            .dasc_source = "vm_mips64.dasc",
            // `lj_arch.h:470-476`.
            .arch_version = if (mipsIsR6(t)) 60 else if (mipsIsR2(t)) 20 else 10,
        },
        // `lj_arch.h:68`: `__mips__`/`__mips`/`__MIPS__`/`__MIPS`. As above,
        // `.mipsel` is the little-endian `Cpu.Arch` and `lj_arch.h:401-405`
        // accepts it.
        .mips, .mipsel => .{
            .arch = .mips,
            .os = os,
            .bits = 32, // `lj_arch.h:453-455`.
            // As in the `mips64` branch above: `.mips` is the big-endian
            // `Cpu.Arch` and `.mipsel` the little-endian one, and
            // `lj_arch.h:401-405`, `:419` and `:434` want this field to say so.
            .big_endian = t.cpu.arch.endian() == .big,
            .has_fpu = !std.Target.mips.featureSetHas(t.cpu.features, .soft_float),
            .soft_fp = std.Target.mips.featureSetHas(t.cpu.features, .soft_float),
            .pauth = false,
            .vm_output = vmOutput(os),
            .dasc_source = "vm_mips.dasc",
            .arch_version = if (mipsIsR6(t)) 60 else if (mipsIsR2(t)) 20 else 10,
        },
        // `lj_arch.h:69`: no branch names this architecture.
        else => return error.ArchitectureNotSupported,
    };
}

/// `LJVM_MODE` (`src/Makefile:510`, `:559-562`, `:576-583`).
fn vmOutput(os: Os) VmOutput {
    return switch (os) {
        .windows => .pe_obj,
        .osx => .mach_asm,
        else => .elf_asm,
    };
}

/// `LJ_ARCH_VERSION` for ARM, from the `__ARM_ARCH*` rules of
/// `lj_arch.h:266-276`.
///
/// Zig has no `__ARM_ARCH` macro to read; the same information is the CPU
/// model name (`armv6t2`, `armv7ve`, ...), which is what this matches. A model
/// with no version in its name falls to `lj_arch.h:274-276`'s `#else`, which is
/// `50`.
fn armArchVersion(t: std.Target) ?u32 {
    const name = t.cpu.model.name;
    // `lj_arch.h:266-267`: `__ARM_ARCH >= 8 || __ARM_ARCH_8__ || __ARM_ARCH_8A__`.
    if (std.mem.indexOf(u8, name, "armv8") != null or
        std.mem.indexOf(u8, name, "armv9") != null) return 80;
    // `lj_arch.h:268-269`.
    if (std.mem.indexOf(u8, name, "armv7") != null) return 70;
    // `lj_arch.h:270-271`.
    if (std.mem.indexOf(u8, name, "armv6t2") != null) return 61;
    // `lj_arch.h:272-273`.
    if (std.mem.indexOf(u8, name, "armv6") != null) return 60;
    // `lj_arch.h:274-276`.
    return 50;
}

/// `LJ_TARGET_MIPSR6` (`lj_arch.h:402-405`), from `__mips_isa_rev >= 6`.
fn mipsIsR6(t: std.Target) bool {
    const f = t.cpu.features;
    return std.Target.mips.featureSetHas(f, .mips32r6) or
        std.Target.mips.featureSetHas(f, .mips64r6);
}

/// `LJ_ARCH_VERSION`'s R2 case (`lj_arch.h:472-474`), from
/// `_MIPS_ARCH_MIPS32R2`/`_MIPS_ARCH_MIPS64R2`.
fn mipsIsR2(t: std.Target) bool {
    const f = t.cpu.features;
    return std.Target.mips.featureSetHas(f, .mips32r2) or
        std.Target.mips.featureSetHas(f, .mips64r2);
}

/// The `-D` macros that pin the target ABI on **both** the target compile line
/// and the host compile line of the generators.
///
/// `src/Makefile:203` puts `$(TARGET_ARCH)` on `HOST_ACFLAGS`, which is why
/// `buildvm` is a host program that still emits target code: `TARGET_ARCH`
/// accumulates across `src/Makefile:244-287` and `:428-453`. This returns that
/// same set, with the three CET and arm64e macros added that upstream leaves to
/// its probe.
pub fn targetArchMacros(s: Selection, allocator: std.mem.Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const add = struct {
        fn f(list: *std.ArrayList([]const u8), alloc: std.mem.Allocator, name: []const u8) void {
            list.append(alloc, name) catch @panic("OOM");
        }
    }.f;

    // `src/Makefile:286`.
    add(&out, allocator, b(allocator, "LUAJIT_TARGET=LUAJIT_ARCH_{s}", .{
        .s = @tagName(s.arch),
    }));

    // `lj_arch.h:281-284`: `__AARCH64EB__` names the big-endian arm64 variant.
    if (s.arch == .arm64 and s.big_endian) add(&out, allocator, "__AARCH64EB__=1");

    // `src/Makefile:254-256` for PowerPC and `:262` for MIPS: forced because a
    // cross-compiling host's own predefines would otherwise describe the host.
    //
    // MIPS is the one place the relationship is a negation, so it is stated
    // rather than left to be re-derived: `lj_arch.h:401` reads `__MIPSEL__`, and
    // `:419`/`:434` make it mean `LUAJIT_LE`/`LUAJIT_BE`. The macro belongs on
    // exactly the little-endian MIPS targets -- the complement of `big_endian`,
    // which is what `lj_arch.h:419` and the `-D__MIPSEL__=1` at
    // `src/Makefile:260-262` both say.
    switch (s.arch) {
        .ppc => add(&out, allocator, "LJ_ARCH_ENDIAN=LUAJIT_BE"),
        .mips, .mips64 => if (!s.big_endian) add(&out, allocator, "__MIPSEL__=1"),
        else => {},
    }

    // `src/Makefile:428-431` and `:432-437`.
    // `@intFromBool`, not the bool itself: `{d}` is an integer format and the
    // preprocessor wants the digits `0` or `1`, which is exactly what upstream's
    // `-DLJ_ARCH_HASFPU=1` writes (`src/Makefile:428-431`, `:432-437`).
    add(&out, allocator, b(allocator, "LJ_ARCH_HASFPU={d}", .{@intFromBool(s.has_fpu)}));
    add(&out, allocator, b(allocator, "LJ_ABI_SOFTFP={d}", .{@intFromBool(s.soft_fp)}));

    // `src/Makefile:441-444`. `LJ_NO_UNWIND` reaches this build only through
    // `LUAJIT_NO_UNWIND` (`lj_arch.h:713`), which nothing here defines, so the
    // flag is never added -- recorded here rather than left implied.
    //
    // `src/Makefile:438-449` derives `PAUTH`, `BRANCH_TRACK` and `SHADOW_STACK`
    // from the probe dump. They are pinned instead, so the C compile and the
    // DynASM run cannot disagree about them. `__CET__` is a compiler
    // command-line choice with no `std.Target` counterpart; a `zig cc` line
    // never passes `-fcf-protection`, so `0` is what the compiler would report.
    add(&out, allocator, b(allocator, "LJ_ABI_PAUTH={d}", .{@intFromBool(s.pauth)}));
    add(&out, allocator, "LJ_ABI_BRANCH_TRACK=0");
    add(&out, allocator, "LJ_ABI_SHADOW_STACK=0");

    return out.items;
}

/// The DynASM `-D` names `DASM_AFLAGS` produces (`src/Makefile:409-486`).
///
/// The caller emits each as two argv elements, `-D` and the name, which is what
/// `dynasm/dynasm.lua:196-205` parses.
pub fn dynasmDefines(s: Selection, allocator: std.mem.Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const add = struct {
        fn f(list: *std.ArrayList([]const u8), alloc: std.mem.Allocator, name: []const u8) void {
            list.append(alloc, name) catch @panic("OOM");
        }
    }.f;

    // `src/Makefile:409-413`. This is the DynASM half of the same
    // `LJ_ARCH_ENDIAN` `lj_arch.h` computed and `targetArchMacros` pinned above:
    // upstream reads `LJ_LE 1` out of the preprocessor dump, and `LJ_LE` is
    // `LJ_ARCH_ENDIAN == LUAJIT_LE` (`lj_arch.h:659-669`). So `big_endian` has
    // to mean the same thing to both consumers, which is why the MIPS branches
    // of `select` assign it from `Cpu.Arch.endian()` rather than naming the
    // `__MIPSEL__` targets directly.
    add(&out, allocator, if (s.big_endian) "ENDIAN_BE" else "ENDIAN_LE");
    // `src/Makefile:414-416`.
    if (s.bits == 64) add(&out, allocator, "P64");
    // `src/Makefile:417-420`. `LJ_HASJIT` (`lj_arch.h:611-615`) is 1 because
    // nothing here defines `LUAJIT_DISABLE_JIT`, `LJ_ARCH_NOJIT` or
    // `LJ_OS_NOJIT`, and `LJ_HASFFI` (`lj_arch.h:618-622`) is 1 for the same
    // reason. The JIT and the FFI are what this package delivers; an
    // interpreter-only build is not LuaJIT.
    add(&out, allocator, "JIT");
    add(&out, allocator, "FFI");
    // `src/Makefile:423-425` with `lj_arch.h:580-586`.
    if (dualNum(s)) add(&out, allocator, "DUALNUM");
    // `src/Makefile:426-431`.
    if (s.has_fpu) add(&out, allocator, "FPU");
    // `src/Makefile:432-437`: `HFABI` exactly when `LJ_ABI_SOFTFP` is not 1.
    if (!s.soft_fp) add(&out, allocator, "HFABI");
    // `src/Makefile:438-441`: `NO_UNWIND`, never, as recorded above.
    // `src/Makefile:442-445`.
    if (s.pauth) add(&out, allocator, "PAUTH");
    // `src/Makefile:446-449`: `BRANCH_TRACK` and `SHADOW_STACK`, both pinned to
    // 0 above, so neither is passed.
    // `src/Makefile:454`: `VER`, only where `lj_arch.h` defines
    // `LJ_ARCH_VERSION`. See `Selection.arch_version` for why PowerPC and the
    // two x86 variants carry none.
    if (s.arch_version) |v| add(&out, allocator, b(allocator, "VER={d}", .{v}));
    // `src/Makefile:455-457`.
    if (s.os == .windows) add(&out, allocator, "WIN");
    // `src/Makefile:468-470`: `MIPSR6`, gated on `LJ_TARGET_MIPSR6`.
    // `lj_arch.h:401-405` sets that from `__mips_isa_rev >= 6`, which is a
    // capability `std.Target` does carry, and `mipsIsR6` already turns it into
    // `Selection.arch_version` 60 -- so unlike the PowerPC names below, this one
    // has a counterpart on both sides of the build and has to be passed.
    //
    // `.mips64` and only `.mips64`: `lj_arch.h`'s `LJ_TARGET_MIPSR6` is in the
    // 64-bit branch, and `vm_mips64.dasc` reads the name 46 times where
    // `vm_mips.dasc` never reads it at all. Left unpassed, all 46 of those
    // guards take the non-R6 arm.
    if (s.arch == .mips64 and s.arch_version == 60) add(&out, allocator, "MIPSR6");
    // `src/Makefile:471-475`: the PowerPC `SQRT`, `ROUND` and `GPR64`. Each is
    // gated on a predefine `std.Target` cannot name -- `_ARCH_PPCSQ` for
    // `SQRT` and `LJ_TARGET_CONSOLE` for `GPR64` (`lj_arch.h:386`, `:365-366`),
    // `_ARCH_PWR5X` for `ROUND` (`:389`). The first two are unreachable for any
    // target this file accepts: `_ARCH_PPCSQ` is a PowerPC-64 macro and
    // `select` refuses `.powerpc64` outright (`lj_arch.h:369-370`,
    // `Unsupported.Ppc64NotSupported`), and no `Arch`/`Os` pair here is a
    // console build. `ROUND` is the reachable one and still needs nothing,
    // because no `vm_*.dasc` reads it.
    return out.items;
}

/// `LJ_DUALNUM` (`lj_arch.h:580-586`) from `LJ_ARCH_NUMMODE`
/// (`lj_arch.h:200`, `:215`, `:264`, `:352-355`, `:468`).
///
/// `LUAJIT_NUMMODE` is undefined here, so `lj_arch.h:576-579`'s mismatch check
/// never fires and the value reduces to the first arm of `lj_arch.h:580-583`.
fn dualNum(s: Selection) bool {
    return switch (s.arch) {
        // `LJ_NUMMODE_SINGLE_DUAL` is 1 only when `LUAJIT_NUMMODE == 2`.
        .x86, .x64 => false,
        // `LJ_NUMMODE_DUAL` is 1 unconditionally.
        .arm, .arm64, .mips, .mips64 => true,
        // `LJ_ARCH_NUMMODE` is `LJ_NUMMODE_DUAL_SINGLE` for hard-float PowerPC
        // (`lj_arch.h:354`) and `LJ_NUMMODE_DUAL` for soft-float
        // (`lj_arch.h:352`); both reach `lj_arch.h:580-583` as 1.
        .ppc => true,
    };
}

/// The `-m` mode `buildvm` emits the VM in (`src/Makefile:510`, `:562`, `:685-687`).
pub fn vmMode(s: Selection) []const u8 {
    return switch (s.vm_output) {
        .elf_asm => "elfasm",
        .mach_asm => "machasm",
        .pe_obj => "peobj",
    };
}

/// The `LUAJIT_OS_*` define `src/Makefile:365-377` puts on the host compile
/// line when the host OS and the target OS differ.
pub fn osMacro(s: Selection, allocator: std.mem.Allocator) []const u8 {
    // `@tagName` is not the spelling: `src/lj_arch.h:36-41` names these
    // LUAJIT_OS_OTHER, _WINDOWS, _LINUX, _OSX, _BSD and _POSIX, all in upper
    // case. Four of the six enum tags differ from it, and an unknown
    // identifier in `#if` is zero, so `LJ_TARGET_WINDOWS` (lj_arch.h:123)
    // silently became 0 and `buildvm` compiled its "no PE object support"
    // stub (`src/host/buildvm_peobj.c:464-471`).
    const name = switch (s.os) {
        .other => "OTHER",
        .windows => "WINDOWS",
        .linux => "LINUX",
        .osx => "OSX",
        .bsd => "BSD",
        .posix => "POSIX",
    };
    return b(allocator, "LUAJIT_OS=LUAJIT_OS_{s}", .{ .s = name });
}

fn b(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []u8 {
    return allocator.print(fmt, args) catch @panic("OOM");
}