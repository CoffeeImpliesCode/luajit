# UPSTREAM

| Field | Value |
|---|---|
| Project | LuaJIT, a Just-In-Time compiler for Lua |
| Canonical site | <https://luajit.org/> |
| Repository | <https://github.com/LuaJIT/LuaJIT> |
| Commit | `c6ffc141a8762b41703f9287d63d93622a13dd8f` |
| Release | `2.1.1788856981`, rolling release; `.relver` is `1788856981` |
| Commit timestamp | `2026-09-08T08:43:01Z` |
| Source archive | <https://codeload.github.com/LuaJIT/LuaJIT/tar.gz/c6ffc141a8762b41703f9287d63d93622a13dd8f> |
| Archive SHA-256 | `6e5fec07750add912e7c3eae0c194d24cd6d023714e1f04a0298a5b4819e4457` |
| Imported paths | 233; complete snapshot, no patch |
| Removed upstream files | None |

LuaJIT has no `v2.1.x` release tag after `v2.1.0-beta3`. The version is generated from `.relver` as `LuaJIT 2.1.1788856981`; the identity symbol is `luaJIT_version_2_1_1788856981`.

## Imported path inventory

| Path group | Count |
|---|---:|
| `src/` | 194 |
| `dynasm/` | 14 |
| `doc/` | 16 |
| `etc/` | 2 |
| Root paths: `.gitattributes`, `.gitignore`, `.relver`, `COPYRIGHT`, `Makefile`, `README`, `README.upstream.md` | 7 |
| **Total** | **233** |

`README.upstream.md` is upstream's `README` at a fork-specific path. Both paths have identical bytes and share one digest. `UPSTREAM.sha256` records 232 paths (231 distinct files); the upstream digest for the fork-extended root `.gitignore` is in its header.

## Upstream files not installed

| Paths | Scope |
|---|---|
| `Makefile`, `src/Makefile`, `src/Makefile.dep` | Retained in the source package; not installed |
| `src/host/` (13 files) | Build-host tools and inputs; not installed |

## Integrity

`UPSTREAM.sha256` lists the upstream file digests and exclusions. The root `.gitignore` retains upstream's original 12 lines, followed by the fork's own block. No upstream source files were removed.
