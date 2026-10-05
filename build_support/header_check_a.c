/* SPDX-License-Identifier: MIT
 */
/*
** header_check_a.c -- the entry point of the installed-header gate.
**
** This program is compiled against the **installed** header tree and linked
** against the **installed** library, not against this repository's `src/`. That
** is the whole point of the step: a build in which the archive is right but the
** headers a consumer sees are missing, stale or in the wrong directory passes
** every in-tree gate and fails here.
**
** The include spelling is `<lua.h>`, not `<luajit-2.1/lua.h>`, because that is
** what `etc/luajit.pc` produces: `Cflags: -I${includedir}` with
** `includedir=${prefix}/include/luajit-2.1` (`etc/luajit.pc:13`, `:25`). A
** consumer that adds the parent directory instead would compile against a
** header this package never installs.
**
** `header_check_b.c` is the second translation unit. Two units prove the header
** set and the archive serve a multi-file program.
**
** The source is the fork's own gate program and contains no upstream text.
*/

#include <lua.h>
#include <lualib.h>
#include <luajit.h>

#include <stdio.h>

/* Defined in header_check_b.c, called from `main` here. Two translation units,
** so the archive has to satisfy both. */
void ljh_run_all(void);

/* Defined in header_check_b.c and read here. */
extern int ljh_failures;

int main(void)
{
  /*
  ** The version string, read out of the generated `luajit.h`.
  **
  ** `luajit_rolling.h:33` spells `LUAJIT_VERSION` as `LuaJIT 2.1.ROLLING`, and
  ** `genversion.lua:36` substitutes the pinned commit's POSIX timestamp for
  ** `ROLLING`, so this reads `LuaJIT 2.1.<relver>`. The prefix and the two
  ** component version numbers are upstream's own (`luajit_rolling.h:33-34`,
  ** `Makefile:16-18`); the trailing digits are the pinned snapshot's, taken from
  ** the checked-in `.relver` rather than from git.
  */
  printf("installed header reports LUAJIT_VERSION = %s\n", LUAJIT_VERSION);
  printf("installed header reports LUAJIT_VERSION_NUM = %d\n", LUAJIT_VERSION_NUM);

  /* `lua.h:19-20`: the Lua 5.1 release strings LuaJIT keeps. */
  printf("installed header reports LUA_VERSION = %s\n", LUA_VERSION);
  printf("installed header reports LUA_RELEASE = %s\n", LUA_RELEASE);

  /* `lj_arch.h:124-126`: the JIT status mode names, so this translation unit
  ** sees the same enumeration header_check_b.c uses. */
  printf("LUAJIT_MODE_ENGINE=0x%04x LUAJIT_MODE_ON=0x%04x\n",
         (unsigned)LUAJIT_MODE_ENGINE, (unsigned)LUAJIT_MODE_ON);

  /* Now the behaviour, all of it in the other translation unit. */
  ljh_run_all();

  printf("\n%d failure(s)\n", ljh_failures);
  /* A non-zero exit is how this program reports failure, the same convention
  ** `tests/geodtest.c` uses in this workspace's other native gates. */
  return ljh_failures == 0 ? 0 : 1;
}