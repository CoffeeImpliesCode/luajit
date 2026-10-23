# NOTICE

## Upstream attribution

LuaJIT is Copyright (C) 2005-2026 Mike Pall. `COPYRIGHT` preserves three upstream grants:

| Grant | Licence | Holder |
|---|---|---|
| LuaJIT | MIT | Mike Pall |
| Included Lua 5.1/5.2 code | MIT | Lua.org, PUC-Rio (1994-2012) |
| dlmalloc | Public domain | Doug Lea (pre-2.8.4, 2006-03-29) |

## Per-path notices

`UPSTREAM.sha256` records 232 upstream paths and 231 distinct files. Upstream's `README` and this fork's `README.upstream.md` have identical bytes and share a digest. The root `.gitignore` retains upstream's 12 lines and adds a fork block; its upstream digest is in the record header.

| Path group | Notice or grant | Count |
|---|---|---:|
| Files with LuaJIT notice only | Mike Pall, MIT | 188 |
| `src/lib_aux.c`, `src/lib_debug.c`, `src/lib_init.c`, `src/lib_os.c`, `src/lib_string.c`, `src/lib_table.c`, `src/lj_api.c`, `src/lj_func.c`, `src/lj_gc.c`, `src/lj_lex.c`, `src/lj_meta.c`, `src/lj_obj.h`, `src/lj_parse.c`, `src/lj_state.c`, `src/lj_tab.c`, `src/luajit.c` | Mike Pall and Lua.org, MIT | 16 |
| `src/lib_package.c` | Mike Pall and Lua.org, MIT | 1 |
| `src/lua.h` | Lua.org, MIT; Copyright (C) 1994-2008 Lua.org, PUC-Rio | 1 |
| `src/host/minilua.c` | Lua.org, MIT; Copyright (C) 1994-2012 Lua.org, PUC-Rio | 1 |
| `src/lj_alloc.c` | Doug Lea, public domain | 1 |
| `src/lj_char.c`, `src/lj_char.h`, `src/lj_alloc.h`, `src/nxbuild.bat`, `src/xb1build.bat`, `src/xedkbuild.bat`, `src/ps4build.bat`, `src/ps5build.bat`, `src/psvitabuild.bat` | Public domain | 9 |
| `.gitattributes`, `.relver`, `doc/bluequad-print.css`, `doc/bluequad.css`, `doc/img/contact.png`, `etc/luajit.pc`, `src/.gitignore`, `src/Makefile.dep`, `src/host/.gitignore`, `src/host/README`, `src/host/buildvm_libbc.h`, `src/jit/.gitignore`, `src/lauxlib.h`, `src/lua.hpp` | No notice in file; covered by `COPYRIGHT` | 14 |
| `COPYRIGHT` | All three upstream grants | 1 |
| **Total recorded paths** |  | **232** |

`src/lj_alloc.c` states: "This is a version (aka dlmalloc) of malloc/free/realloc written by Doug Lea and released to the public domain, as explained at https://creativecommons.org/licenses/publicdomain. ** Version pre-2.8.4 Wed Mar 29 19:46:29 2006 (dl at gee) ** No additional copyright is claimed over the customizations."

The first four public-domain files in the table are in the compiled closure: `src/lj_alloc.c`, `src/lj_char.c`, `src/lj_char.h`, and `src/lj_alloc.h`. The other six are build scripts.

The nine donated files carry "Donated to the public domain." except `src/nxbuild.bat`, which says "Donated to the public domain by Swyter."

The 14 files without their own notice are covered by `COPYRIGHT`: `src/host/README` by the LuaJIT grant, `src/lua.hpp` by the Lua.org grant, and documentation assets by the LuaJIT grant.

## Path groups

- `dynasm/`: 14 files of DynASM 1.5.0, part of LuaJIT and covered by Mike Pall's MIT grant. The full MIT text is in `dynasm/dynasm.lua` and generated headers.
- `doc/`: 16 files of LuaJIT's HTML manual, covered by the LuaJIT grant.
- LuaJIT and Lua.org notices in the 16 listed files are separate grants with separate holders; redistributors must include both.

## Fork-authored files

Fork-authored files are under the MIT grant in `FORK-LICENSE.md`, held by "the luajit Zig SDK fork authors". Mike Pall's and Lua.org's grants do not cover those files.

The root `.gitignore` has two scopes: upstream's original 12 lines retain upstream terms; the appended Zig block is under the fork's grant. `README.upstream.md` is upstream's README at a fork-specific path and is not under the fork's grant.

## Distribution

`zig build install` and both Nix outputs ship unmodified `COPYRIGHT` at `share/doc/luajit-2.1/COPYRIGHT`, the fork's README beside it, and `share/licenses/luajit/{NOTICE.md,FORK-LICENSE.md,UPSTREAM.md,README.upstream.md}`.
