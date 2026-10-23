# FORK-LICENSE.md — the licence for this fork's own files

Upstream grants are in [`COPYRIGHT`](COPYRIGHT); [`NOTICE.md`](NOTICE.md) records per-file licences. This file grants MIT only to fork-authored files listed below.

## Authorization

The repository owner authorized per-project licences for fork additions, matching primary upstream terms where appropriate.

## Grant

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

## Files covered

Every fork-authored file is covered, except where marked upstream below.

| Path | Covered content |
|---|---|
| `build.zig` | Build graph, generators, and install rules |
| `build.zig.zon` | Manifest, `.paths`, and rolling version |
| `build_support/` | `sources.zig`, `abi.zig`, `graph.zig`, `translate.h`, `native_selfcheck.lua` |
| `.gitignore` | Only the fork-appended Zig block |
| `zig/*.zig` | Facade components, including `root.zig` |
| `runtime/graph.zig` | Runtime dispatch and provider descriptor |
| `runtime/library.zig` | Typed runtime-loading entry points |
| `runtime/loader.zig` | Shared loader core: load, table, and READY publication |
| `runtime/generate.zig` | Dispatch generator |
| `runtime/sync.c`, `runtime/sync.h` | Namespaced synchronization |
| `tests.zig` | Behavioural tests |
| `smoke.zig` | Deterministic example program |
| `consumer/build.zig` | Dependent package build |
| `consumer/build.zig.zon` | Dependent package manifest |
| `consumer/src/main.zig` | Dependent program |
| `cross-test.profile.sh` | Harness settings for the 53-platform matrix |
| `package.nix` | Source-only Nix derivation |
| `flake.nix` | Static, shared, and default variants |
| `flake.lock` | Locked flake inputs |
| `devenv.nix` | Development shell |
| `devenv.yaml` | Development-shell input |
| `.envrc` | Direnv entry point |
| `README.md` | Fork README |
| `README.zig.md` | Zig interface reference |
| `CHANGELOG.md` | Fork changes |
| `FORK-NOTES.md` | Fork decisions |
| `FORK-LICENSE.md` | This grant |
| `NOTICE.md` | Per-file licence inventory |
| `UPSTREAM.md` | Upstream pin and import record |
| `UPSTREAM.sha256` | Digests of shipped upstream files |

## Upstream material excluded from this grant

`README` and `README.upstream.md` are the same 438-byte upstream README at two paths. Both are in `.paths` and `UPSTREAM.sha256`; neither is covered by this grant.

`.gitignore` keeps upstream's first 12 lines verbatim and appends the fork's Zig block. The upstream lines retain upstream terms; the appended block is covered here, so the whole file has no single grant. `UPSTREAM.sha256` notes the upstream bytes rather than hashing the mixed file; `NOTICE.md` records both portions.

All 233 upstream paths retain their own terms: 232 records in `UPSTREAM.sha256` cover 231 distinct files because the README is recorded twice, plus the upstream portion of `.gitignore`. They carry the LuaJIT MIT grant, Lua.org MIT grant, or dlmalloc public-domain notice from `COPYRIGHT`; `dynasm/` and `doc/` retain the project notice. `NOTICE.md` is the per-file inventory.

These generated files are upstream output, not fork-authored or relicensed: `src/luajit.h`, `src/luajit_relver.txt`, `src/lj_bcdef.h`, `src/lj_ffdef.h`, `src/lj_libdef.h`, `src/lj_recdef.h`, `src/lj_folddef.h`, `src/lj_vm.S`, and `src/host/buildvm_arch.h`.

## Notice delivery

MIT requires its copyright and permission notices with all copies or substantial portions. `zig build install` installs upstream `COPYRIGHT` and `share/licenses/luajit/{NOTICE.md,FORK-LICENSE.md,UPSTREAM.md,README.upstream.md}`; Nix static and shared builds use that same install step. `COPYRIGHT` is installed unmodified and retains all upstream grants.

See [`NOTICE.md`](NOTICE.md) for the per-file inventory and [`UPSTREAM.md`](UPSTREAM.md) for the import record.