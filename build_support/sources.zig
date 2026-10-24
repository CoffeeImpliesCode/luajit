// SPDX-License-Identifier: MIT
//! The translation units upstream's own `src/Makefile` compiles, transcribed
//! from it.
//!
//! Every list here is a copy of an upstream assignment, with its line range:
//!
//!   * `ljl_sources`   -- `src/Makefile:512-514` (`$(LJLIB_O)`)
//!   * `ljcore_sources`-- `src/Makefile:517-530` (`$(LJCORE_O)`)
//!   * `ljvm_sources`  -- `src/Makefile:532-533` (`$(LJVMCORE_O)`)
//!   * `front_end`     -- `src/Makefile:538` (`$(LUAJIT_O)`), the `luajit` CLI
//!   * `buildvm_sources` -- `src/Makefile:499-502` (`$(BUILDVM_O)`)
//!   * `host_minilua` -- `src/Makefile:392`, `$(MINILUA_O)`
//!   * `generated_headers` -- `src/Makefile:544-545` (`$(ALL_HDRGEN)`)
//!   * `jit_modules`   -- `Makefile:99-104` (`$(FILES_JITLIB)`), the install list
//!   * `public_headers` -- `Makefile:98` (`$(FILES_INC)`)
//!
//! Nothing is filtered. `ljamalg.c` is upstream's own amalgamation entry point
//! (`src/Makefile:636-637`, `amalg:`) and is deliberately absent: it `#include`s
//! the same sources, so compiling it would define every symbol twice.
//! `src/host/buildvm_libbc.h` is a *checked-in* file, not a generated one --
//! `src/Makefile:642-644`'s `libbc` target regenerates it from a fully built
//! `luajit`, and this tree already carries the result -- so nothing here has to
//! produce it.

const std = @import("std");

/// `src/Makefile:499-502`, `$(BUILDVM_O)`.
pub const buildvm_sources = [_][]const u8{
    "host/buildvm.c",
    "host/buildvm_asm.c",
    "host/buildvm_peobj.c",
    "host/buildvm_lib.c",
    "host/buildvm_fold.c",
};

/// `src/Makefile:392`, `$(MINILUA_O)`. `src/host/minilua.c` is checked in: it is
/// upstream's minified Lua 5.1.5 amalgamation, produced by
/// `src/host/genminilua.lua`, which needs a Lua 5.1.5 source tree that this
/// repository does not carry and this build does not fetch. The generated file
/// upstream ships is the file upstream's own `src/Makefile:666` compiles.
pub const minilua_source = "host/minilua.c";

/// `src/Makefile:517-530`, `$(LJCORE_O)`, in upstream's order and on upstream's
/// own line breaks.
pub const ljcore_sources = [_][]const u8{
    "lj_assert.c",     "lj_gc.c",        "lj_err.c",        "lj_char.c",    "lj_bc.c",
    "lj_obj.c",        "lj_buf.c",       "lj_str.c",        "lj_tab.c",     "lj_func.c",
    "lj_udata.c",      "lj_meta.c",      "lj_debug.c",      "lj_prng.c",    "lj_state.c",
    "lj_dispatch.c",   "lj_vmevent.c",   "lj_vmmath.c",     "lj_strscan.c", "lj_strfmt.c",
    "lj_strfmt_num.c", "lj_serialize.c", "lj_api.c",        "lj_profile.c", "lj_lex.c",
    "lj_parse.c",      "lj_bcread.c",    "lj_bcwrite.c",    "lj_load.c",    "lj_ir.c",
    "lj_opt_mem.c",    "lj_opt_fold.c",  "lj_opt_narrow.c", "lj_opt_dce.c", "lj_opt_loop.c",
    "lj_opt_split.c",  "lj_opt_sink.c",  "lj_mcode.c",      "lj_snap.c",    "lj_record.c",
    "lj_crecord.c",    "lj_ffrecord.c",  "lj_asm.c",        "lj_trace.c",   "lj_gdbjit.c",
    "lj_ctype.c",      "lj_cdata.c",     "lj_cconv.c",      "lj_ccall.c",   "lj_ccallback.c",
    "lj_carith.c",     "lj_clib.c",      "lj_cparse.c",     "lj_lib.c",     "lj_alloc.c",
    "lib_aux.c",
};

/// `src/Makefile:512-514`, `$(LJLIB_O)`.
pub const ljl_sources = [_][]const u8{
    "lib_base.c", "lib_math.c",   "lib_bit.c",     "lib_string.c", "lib_table.c",
    "lib_io.c",   "lib_os.c",     "lib_package.c", "lib_debug.c",  "lib_jit.c",
    "lib_ffi.c",  "lib_buffer.c",
};

/// `src/Makefile:530` appends this to `$(LJCORE_O)` on the same assignment, so
/// it is the last unit of `$(LJCORE_O)`.
pub const lib_init_source = "lib_init.c";

/// `src/Makefile:538`, `$(LUAJIT_O)`: the CLI's own translation unit.
/// `src/Makefile:727-729` builds it with `$(TARGET_STCC)` only -- never the
/// dynamic-flavoured compile -- so it is separate from the library units.
pub const front_end = "luajit.c";

/// `src/Makefile:544-545`: the DynASM half of `$(ALL_HDRGEN)`.
pub const dynasm_generated_header = "host/buildvm_arch.h";

/// `src/Makefile:544-545`: the `genversion.lua` half of `$(ALL_HDRGEN)`.
pub const version_generated_header = "luajit.h";

/// `src/Makefile:546`, `$(ALL_GEN)`: the VM assembly or object, the headers
/// above, the rolling version stamp, and `jit/vmdef.lua`.
pub const generated_vmdef_lua = "jit/vmdef.lua";

/// `Makefile:99-104`, `$(FILES_JITLIB)`: the Lua modules installed under
/// `share/luajit-2.1/jit`. `src/Makefile:705-707` generates `vmdef.lua` into
/// `src/jit/`, so the last entry is a build output rather than a tree file, and
/// `jit_modules_present` below lists the other eighteen.
pub const jit_modules = [_][]const u8{
    "bc.lua",
    "bcsave.lua",
    "dump.lua",
    "p.lua",
    "v.lua",
    "zone.lua",
    "dis_x86.lua",
    "dis_x64.lua",
    "dis_arm.lua",
    "dis_arm64.lua",
    "dis_arm64be.lua",
    "dis_ppc.lua",
    "dis_mips.lua",
    "dis_mipsel.lua",
    "dis_mips64.lua",
    "dis_mips64el.lua",
    "dis_mips64r6.lua",
    "dis_mips64r6el.lua",
    "vmdef.lua",
};

/// The `jit_modules` entries that are files in `src/jit` today.
pub fn jit_modules_present(allocator: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (jit_modules) |m| {
        if (std.mem.eql(u8, m, std.fs.path.basename(generated_vmdef_lua))) continue;
        try out.append(allocator, m);
    }
    return out.toOwnedSlice(allocator);
}

/// `Makefile:98`, `$(FILES_INC)`: the public headers a consumer includes.
/// `luajit.h` is the generated one; the other five are `src` files.
pub const public_headers = [_][]const u8{
    "lua.h",
    "lualib.h",
    "lauxlib.h",
    "luaconf.h",
    "lua.hpp",
    "luajit.h",
};

/// The `public_headers` entries that exist in `src` now. `luajit.h` does not:
/// `src/.gitignore:2` lists it, and `src/Makefile:670-673` generates it.
pub fn public_headers_present(allocator: std.mem.Allocator) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (public_headers) |h| {
        if (std.mem.eql(u8, h, version_generated_header)) continue;
        try out.append(allocator, h);
    }
    return out.toOwnedSlice(allocator);
}

pub const man_page = "etc/luajit.1";

/// `Makefile:143-144`, the pkg-config template, before `SED_PC`
/// (`Makefile:86-91`) rewrites `prefix=`, `multilib=` and `relver=`.
pub const pkg_config_template = "etc/luajit.pc";
