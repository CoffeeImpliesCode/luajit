# FORK-LICENSE.md — the licence for this fork's own files

Upstream's grant is in [`COPYRIGHT`](COPYRIGHT) and the per-file inventory is
in [`NOTICE.md`](NOTICE.md). This file covers exactly one thing neither of
those can: the licence for the files **this fork wrote**.

## The authorization

The owner of this repository authorized a licence for the fork-authored
additions, to be chosen per project and to match the primary upstream terms
where that is appropriate. That authorization is recorded in this workspace's
own rules at `foundation-libs/AGENTS.md` § 8:

> The owner has now authorized per-project licences for those additions,
> matching the project's primary upstream terms where appropriate. Record that
> authorization and the actual grant in each fork's `FORK-LICENSE.md` and
> `NOTICE.md`; preserve all upstream copyright notices and per-file
> exceptions. Do not attribute fork additions to upstream authors.

This file is the record for this project. It was written on 2026-10-04, in
the contract-migration wave.

## The grant

**SPDX-License-Identifier: `MIT`**

```
MIT License

Copyright (c) 2026 the luajit Zig SDK fork authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Why MIT, and why the same MIT

This is the "matching the primary upstream terms" case. Upstream's own grant
is MIT: `COPYRIGHT:4-24` carries the MIT text for LuaJIT under
`Copyright (C) 2005-2026 Mike Pall`, and upstream's own README says
"LuaJIT is free software, released under the MIT license". The same tree also
carries the Lua 5.1/5.2 grant, which is MIT text again (`COPYRIGHT:29-47`),
and the dlmalloc notice, which is public domain (`COPYRIGHT:52-55`). Nothing
upstream is under a term that MIT would conflict with, so a fork under MIT
adds no obligation the recipient did not already have.

`meta.license` in `package.nix` is `lib.licenses.mit` for the same reason.
It is a **summary**. One `meta.license` cannot express what this repository
contains: three separate upstream grants in one file, a public-domain notice
for the allocator, `dynasm/` and `doc/` under the project notice, and this
fork's MIT over the files below. `NOTICE.md` is the record that can express
it.

### The copyright holder line, and what it deliberately does not say

The holder line reads **"the luajit Zig SDK fork authors"** because no
personal or corporate copyright identity was supplied by the owner for this
fork, and inventing one would put a name in a legal notice no person or
entity has claimed.

It is explicitly **not** Mike Pall, and not Lua.org. Neither wrote `build.zig`,
`zig/root.zig`, `tests.zig`, `smoke.zig`, the Nix files, this document or any
other file listed below. Their copyright over their own work stays where it
belongs: `COPYRIGHT`, and the per-file notices `NOTICE.md` inventories.

## What this grant covers

Every file this fork wrote. The complete list as of this writing:

| Path | What it is |
|---|---|
| `build.zig` | the Zig 0.17 build graph: native closure, generators, install |
| `build.zig.zon` | the package manifest, `.paths` and the rolling `.version` |
| `port017.zig`, `port017_make.zig`, `port017_runtimes.zig` | configure/make compatibility helpers |
| `build_support/` | fork-only build helpers: `sources.zig`, `abi.zig`, `graph.zig`, `translate.h`, `native_selfcheck.lua` |
| `.gitignore` | **only the block this fork appends**; see the note below |
| `zig/root.zig` | the typed Zig facade and the raw C route |
| `build_support/translate.h` | the one header the build translates; its own comment says why |
| `zig/*.zig` | further fork-authored Zig component source |
| `runtime/graph.zig` | the per-library generated dispatch and descriptor |
| `runtime/library.zig` | the typed runtime-loading entry points |
| `runtime/loader.zig` | the shared runtime core: load, table, READY store |
| `runtime/generate.zig` | the shared runtime core's code generator |
| `runtime/sync.c`, `runtime/sync.h` | the shared runtime core's synchronisation |
| `tests.zig` | the package's behavioural tests |
| `smoke.zig` | the deterministic example program |
| `consumer/build.zig` | the separate dependent package's build |
| `consumer/build.zig.zon` | that package's manifest |
| `consumer/src/main.zig` | that package's program |
| `cross-test.profile.sh` | harness settings for the 53-platform matrix |
| `package.nix` | the one source-only Nix derivation |
| `flake.nix` | the `static`, `shared` and `default` variants |
| `flake.lock` | the resolved input lock `flake.nix` pins its `nixpkgs.url` to |
| `devenv.nix` | the canonical development shell and its lazy `outputs` |
| `devenv.yaml` | that shell's nixpkgs input declaration |
| `.envrc` | the direnv entry point for that shell |
| `README.md` | this fork's README |
| `README.upstream.md` | **not this grant** — see below |
| `README` | **not this grant** — upstream's README at its own upstream name, see below |
| `README.zig.md` | the Zig interface documentation |
| `CHANGELOG.md` | the numbered fork-only record |
| `FORK-NOTES.md` | the decisions and what each cost |
| `FORK-LICENSE.md` | this file |
| `NOTICE.md` | the per-file inventory |
| `UPSTREAM.md` | the pin, the import and the native closure |
| `UPSTREAM.sha256` | the digests of the shipped upstream files |

### Three rows in that table are not what they look like

**`README` and `README.upstream.md` are upstream's bytes, at two paths.** They
are the same 438 bytes and `UPSTREAM.sha256:50-51` records both with the same
digest. `README` is upstream's README under its own upstream name;
`README.upstream.md` is the fork-specific name the same file also travels
under, so this fork could put its own `README.md` in its place. Both carry
upstream's grant, not this one, and both are named in `build.zig.zon`'s
`.paths`, because a fetched copy that shipped only the renamed one would carry
a digest record with no file behind it. They are listed above only so the list
is exhaustive; the grant does not reach either of them.

**`.gitignore` is a file this fork extended, not one it wrote.** Upstream's
twelve lines are kept verbatim at the head of the working-tree file and the
fork's Zig block is appended below them. The upstream half stays under
upstream's terms; the appended block is under the grant above. The file as a
whole therefore has no single grant, and it is the one path in this
repository with no digest in `UPSTREAM.sha256`. `NOTICE.md` records both
halves.

## What this grant does not cover

* **Every upstream file.** All 233 upstream paths keep upstream's own terms:
  the 232 recorded in `UPSTREAM.sha256`, which are 231 distinct files because
  the README is recorded at both of its paths, plus `.gitignore`, whose own
  upstream bytes are recorded there as a comment rather than as a record
  because this fork appended to that file. The LuaJIT MIT grant, the Lua.org
  MIT grant it carries in `COPYRIGHT`, and the dlmalloc public-domain notice
  are what they carry. `NOTICE.md` is the per-file inventory and
  `UPSTREAM.sha256` fails loudly if any of those bytes changes.
* **The generated build products.** `src/luajit.h`, `src/luajit_relver.txt`,
  `src/lj_bcdef.h`, `src/lj_ffdef.h`, `src/lj_libdef.h`, `src/lj_recdef.h`,
  `src/lj_folddef.h`, `src/lj_vm.S` and `src/host/buildvm_arch.h` are produced
  from upstream sources by upstream's own generators. They are upstream's
  output, carry upstream's grant, and are not re-licensed here.

## Obligations this grant creates, and how they are discharged

MIT requires the copyright notice and the permission notice to travel with
"all copies or substantial portions of the Software". Both delivery paths in
this repository install them:

| Path | What a recipient gets |
|---|---|
| `zig build install` | the library, the six public headers, the `jit` modules, the `luajit` tool, the manual page, `luajit.pc`, upstream's `COPYRIGHT` at `share/doc/luajit-2.1/`, this fork's `README.md` beside it, and `share/licenses/luajit/{NOTICE.md,FORK-LICENSE.md,UPSTREAM.md,README.upstream.md}` |
| `nix build .#static` / `.#shared` | **exactly the same files**, because the whole closure — records included — is written by that one `zig build install` step. `package.nix` contributes the prefix, the Zig caches and the flags, and installs nothing itself. |

`COPYRIGHT` itself already contains three grants in one file, upstream's and
Lua.org's and the dlmalloc notice; it is installed unmodified. Nothing in the
fork's own files replaces it or narrows it.

## See also

* [`COPYRIGHT`](COPYRIGHT) — upstream's three grants, verbatim
* [`NOTICE.md`](NOTICE.md) — the per-file inventory and the attribution
* [`UPSTREAM.md`](UPSTREAM.md) — the pin, the rolling version derivation and
  the native closure