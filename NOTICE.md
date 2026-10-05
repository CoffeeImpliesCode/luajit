# NOTICE

The per-file licence and attribution record for this fork. It exists because
the LuaJIT tree is **not one licence**: `COPYRIGHT` carries three grants in
one file, ten files were donated to the public domain — four of them inside
the compiled closure — and this fork's own files carry a separate grant.

Nothing here re-licenses anything. `UPSTREAM.sha256` is what keeps the
upstream bytes honest.

## Upstream work

LuaJIT is the work of **Mike Pall**. Upstream's own `README:8` says
`LuaJIT is Copyright (C) 2005-2026 Mike Pall`, and `COPYRIGHT:4` says
`Copyright (C) 2005-2026 Mike Pall. All rights reserved.`

Three distinct upstream grants are in play, and `COPYRIGHT` keeps them
separate on purpose. Each block is preserved byte for byte:

| `COPYRIGHT` | Grant | Holder |
|---|---|---|
| `:1-24` | MIT, LuaJIT | Mike Pall |
| `:26-47` | MIT, the Lua 5.1/5.2 code LuaJIT includes | Lua.org, PUC-Rio — `Copyright (C) 1994-2012` |
| `:49-55` | public domain, dlmalloc | Doug Lea — *"released to the public domain, as explained at https://creativecommons.org/licenses/publicdomain"*, version pre-2.8.4, 2006-03-29 |

## The complete per-file inventory

All **232** upstream files this package ships with a digest. "LuaJIT notice"
means the file's own bytes contain the project's `2005-2026` copyright line,
in a C comment, a Lua comment, a batch-file `@rem` or an HTML `<meta>`.

Those 232 records are 232 **paths** and 231 distinct files: upstream's README
is present twice, at `README` under its own name and at `README.upstream.md`
under this fork's, with identical bytes and one digest written against both
(`UPSTREAM.sha256:42-51`). Every other record is one path and one file, so
every row below is counted per path. Both README paths are named in
`build.zig.zon`'s `.paths`: a fetched copy that shipped only the renamed one
would carry a digest record with no file behind it.

| Classification | Count |
|---|---|
| LuaJIT notice only | 188 |
| LuaJIT notice **and** Lua.org `1994-2008` notice | 16 |
| LuaJIT notice and Lua.org `1994-2012` notice | 1 |
| Lua.org `1994-2008` notice only | 1 |
| Lua.org `1994-2012` notice only | 1 |
| dlmalloc public-domain notice | 1 |
| Donated to the public domain | 9 |
| No notice in the file's own bytes | 14 |
| `COPYRIGHT` itself (all three grants) | 1 |
| **Total** | **232** |

### Files carrying a second, different notice

These sixteen carry Mike Pall's LuaJIT notice *and* the Lua.org `1994-2008`
notice of the Lua 5.1 code they descend from: `src/lib_aux.c`,
`src/lib_debug.c`, `src/lib_init.c`, `src/lib_os.c`, `src/lib_string.c`,
`src/lib_table.c`, `src/lj_api.c`, `src/lj_func.c`, `src/lj_gc.c`,
`src/lj_lex.c`, `src/lj_meta.c`, `src/lj_obj.h`, `src/lj_parse.c`,
`src/lj_state.c`, `src/lj_tab.c`, `src/luajit.c`.

Three files name Lua.org with the later `1994-2012` date instead:

| File | Notice |
|---|---|
| `src/lua.h` | `Copyright (C) 1994-2008 Lua.org, PUC-Rio` (this is Lua 5.1's own header, unmodified apart from LuaJIT's configuration comments) |
| `src/host/minilua.c` | `Copyright (C) 1994-2012 Lua.org, PUC-Rio` — Lua 5.2's minilua, which LuaJIT uses to run its own build-time generators |
| `src/lib_package.c` | both Mike Pall's `2005-2026` line and Lua.org's `1994-2012` line |

Both Lua.org grants are MIT text, so they impose the same condition as the
LuaJIT one. They are recorded because they are **different grants with
different holders**, and a recipient redistributing this tree owes both
notices.

### The ten public-domain files

Ten files in this tree were given to the public domain by their authors. They
are not MIT, and MIT's notice condition does not reach them. The first four
are **inside the compiled closure**, so a binary built from this source
contains public-domain code:

| File | Notice, verbatim | In the library? |
|---|---|---|
| `src/lj_alloc.c` | *"This is a version (aka dlmalloc) of malloc/free/realloc written by Doug Lea and released to the public domain, as explained at https://creativecommons.org/licenses/publicdomain. ** Version pre-2.8.4 Wed Mar 29 19:46:29 2006 (dl at gee) ** No additional copyright is claimed over the customizations."* (`src/lj_alloc.c:7-13`) | yes — the allocator |
| `src/lj_char.c` | `Donated to the public domain.` (`src/lj_char.c:3`) | yes — character classification |
| `src/lj_char.h` | `Donated to the public domain.` (`src/lj_char.h:3`) | yes — included by the core |
| `src/lj_alloc.h` | `Donated to the public domain.` (`src/lj_alloc.h:3`) | yes — included by the core |
| `src/nxbuild.bat` | `Donated to the public domain by Swyter.` (`:2`) | no — Nintendo build script, not run by this SDK |
| `src/xb1build.bat` | `Donated to the public domain.` (`:2`) | no |
| `src/xedkbuild.bat` | `Donated to the public domain.` (`:2`) | no |
| `src/ps4build.bat` | `Donated to the public domain.` (`:2`) | no |
| `src/ps5build.bat` | `Donated to the public domain.` (`:2`) | no |
| `src/psvitabuild.bat` | `Donated to the public domain.` (`:2`) | no |

(Nine of the ten carry a bare *"Donated to the public domain."* line; the
tenth, `src/lj_alloc.c`, carries Doug Lea's dlmalloc notice.)

`src/lj_alloc.c:13` says *"No additional copyright is claimed over the
customizations"*, so the donations cover LuaJIT's own modifications too. No
recipient of a binary built from this tree owes anything further for those
files.

### The fourteen files with no notice of their own

`.gitattributes`, `.relver`, `doc/bluequad-print.css`, `doc/bluequad.css`,
`doc/img/contact.png`, `etc/luajit.pc`, `src/.gitignore`,
`src/Makefile.dep`, `src/host/.gitignore`, `src/host/README`,
`src/host/buildvm_libbc.h`, `src/jit/.gitignore`, `src/lauxlib.h`,
`src/lua.hpp`.

They are covered by the grants in `COPYRIGHT`. Three of them are worth
naming individually because a reader might expect otherwise:

* `src/host/README` is a four-line prose file that says the host tools must
  not be installed. It is covered by `COPYRIGHT`'s first block.
* `src/lua.hpp` is Lua 5.1's own three-line C++ convenience header, which has
  carried no notice since 5.1. It is covered by the Lua.org block.
* `doc/bluequad.css`, `doc/bluequad-print.css` and `doc/img/contact.png` are
  the documentation's stylesheet and image. They travel with the documentation
  under the project's first block.

### `dynasm/` and `doc/`

Neither is a separately-licensed third-party drop.

* `dynasm/` is **DynASM 1.5.0**, *"Originally designed and implemented for
  LuaJIT"* (`dynasm/dynasm.lua:3`), `author = "Mike Pall"`
  (`dynasm/dynasm.lua:16`), `license = "MIT"` (`dynasm/dynasm.lua:18`), with
  the full MIT text in the same file's `copyright` field
  (`dynasm/dynasm.lua:19-42`) and in every generated `.h`.
  `dynasm/dasm_proto.h:2-5` names the same holder and points at
  `dynasm.lua` for the full notice. Fourteen files, all under Mike Pall's
  MIT grant.
* `doc/` is the project's own HTML manual: sixteen files, each carrying
  `<meta name="Copyright" content="Copyright (C) 2005-2026">`.

## What the MIT condition requires, and where it is met

Upstream's first grant requires the copyright notice and the permission notice
to be included in all copies or substantial portions of the Software. That is
discharged by shipping `COPYRIGHT` unmodified with every delivery, which both
paths do:

| Path | Licence material a recipient receives |
|---|---|
| `zig build install` | `COPYRIGHT` unmodified at `share/doc/luajit-2.1/COPYRIGHT`, this fork's `README.md` beside it, and `share/licenses/luajit/{NOTICE.md,FORK-LICENSE.md,UPSTREAM.md,README.upstream.md}` |
| `nix build .#static` / `.#shared` | **exactly the same files** — the whole closure, records included, is written by that one `zig build install` step, so there is no second writer of any licence path |

`COPYRIGHT` needs no edit, no added block and no narrowing: it already states
all three upstream terms in their own words. This fork appends nothing to it.

## This fork's own files, and the one grant over them

**Every file this fork wrote is under a single grant: MIT (SPDX `MIT`).**
[`FORK-LICENSE.md`](FORK-LICENSE.md) is that record in full, together with the
owner's authorization and the complete file list. In summary:

* The holder is **"the luajit Zig SDK fork authors"**. No personal or
  corporate identity was supplied for this fork, and none was invented.
* Mike Pall's and Lua.org's names reach **none** of the fork's files. Their
  copyright stays with their own work.
* `.gitignore` is the one path with two grants: upstream's twelve lines stay
  under upstream's terms and the fork's appended Zig block is under this one.
* `README.upstream.md` is upstream's `README` at a fork-specific path. It
  carries upstream's terms and is **not** covered by the fork's grant.

## Cryptographic suitability

Not applicable, and stated so rather than left open: this is a Lua language
implementation. It hashes and uses randomness for the FFI, the profiler and
internally for the compiler, and it exports no primitive whose correctness
depends on a cryptographic claim. It is not a cryptographic library and must
not be treated as one.

## See also

* [`COPYRIGHT`](COPYRIGHT) — the three upstream grants, verbatim
* [`FORK-LICENSE.md`](FORK-LICENSE.md) — the authorization and the fork's grant
* [`UPSTREAM.md`](UPSTREAM.md) — the pin, the rolling version derivation, the
  compiled closure
* [`UPSTREAM.sha256`](UPSTREAM.sha256) — the 232 digests