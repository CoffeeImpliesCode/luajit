/* SPDX-License-Identifier: MIT
 */
/*
** translate.h -- the single C translation unit this package has the Zig C
** translator read.
**
** It names the four public C headers and nothing else. `lua.hpp` is
** deliberately absent: it is a C++ header, `Makefile:98` installs it for a C++
** consumer, and `zig translate-c` parses C. A C++ consumer including
** `<lua.hpp>` gets it from the installed header tree.
**
** `luajit.h` is the *generated* one, not `luajit_rolling.h`. The rolling header
** ends in `#error "DO NOT USE luajit_rolling.h -- only include build-generated
** luajit.h"` (`luajit_rolling.h:79`), so translating it would be translating a
** deliberate refusal. The generated header is produced by
** `src/host/genversion.lua` (`src/Makefile:670-673`) and lands in the build
** cache; `build_support/graph.zig` puts its directory on the translation line
** for the same reason it is on the compile line.
**
** Angle brackets, not quotes: a quoted include also searches the directory of
** this file, which would let a stray `lua.h` or `luajit.h` sitting beside the
** package root win over the ones `build_support/graph.zig` put on the line.
** `lua.h` includes `"luaconf.h"` by itself (`lua.h:16`), so `luaconf.h` is
** reached through it rather than named here twice.
**
** Do not copy LuaJIT declarations into this file. Everything below is upstream's
** own, at its own revision.
*/
#ifndef FOUNDATION_LUAJIT_TRANSLATE_H
#define FOUNDATION_LUAJIT_TRANSLATE_H

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <luajit.h>

#endif /* FOUNDATION_LUAJIT_TRANSLATE_H */