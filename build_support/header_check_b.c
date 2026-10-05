/* SPDX-License-Identifier: MIT
 */
/*
** header_check_b.c -- the second translation unit of the installed-header gate.
**
** `header_check_a.c` has `main`. This file exists so the gate proves the
** *installed* include tree and the *installed* library serve a program with more
** than one translation unit: a header set that only works when a single `.c`
** file includes it has not had its macro definitions checked twice, and an
** archive that only ever links from one unit can still be missing an object.
** Both units are compiled against `include/luajit-2.1` in the install tree and
** linked against the installed `libluajit-5.1`, which is the form a C consumer
** gets from `etc/luajit.pc`'s `Cflags: -I${includedir}` and
** `Libs: -L${libdir} -l${libname}`.
**
** Every expectation below is Lua 5.1 or LuaJIT semantics, or a closed-form
** arithmetic fact, not a number this build produced. The source is the fork's
** own gate program and contains no upstream text.
*/

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <luajit.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The failure count, defined here and read by header_check_a.c's `main`. */
int ljh_failures = 0;

/* Only this file checks, so the reporting helper is file-local. */
static void ljh_check(const char *what, int ok, const char *detail)
{
  if (ok) {
    printf("ok   %-42s %s\n", what, detail ? detail : "");
  } else {
    ljh_failures++;
    printf("FAIL %-42s %s\n", what, detail ? detail : "");
  }
}

/*
** Runs a chunk in a fresh state and returns the value it left on the stack.
**
** `luaL_dostring` is `lauxlib.h:116`'s macro -- `luaL_loadstring` then
** `lua_pcall` -- so every chunk below goes through the bytecode compiler *and*
** the reader on the way in.
*/
static double ljh_run(const char *chunk, int *status)
{
  lua_State *L = luaL_newstate();
  double result;
  char detail[128];

  if (L == NULL) {
    *status = -1;
    snprintf(detail, sizeof(detail), "luaL_newstate returned NULL");
    ljh_check("luaL_newstate", 0, detail);
    return 0.0;
  }

  luaL_openlibs(L);
  /*
  ** `luaJIT_setmode` with `LUAJIT_MODE_ENGINE|LUAJIT_MODE_ON` turns the JIT
  ** engine on (`lib_jit.c:46-56`; the mode constants are
  ** `luajit_rolling.h:41-56`). Doing it before the chunk means the hot loop
  ** below is compiled and run by the JIT and not only interpreted, so a build
  ** that quietly lost the JIT fails here rather than passing as an
  ** interpreter.
  */
  luaJIT_setmode(L, 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_ON);

  *status = luaL_dostring(L, chunk);
  result = lua_tonumber(L, -1);
  lua_close(L);
  return result;
}

/* A growable byte buffer for the dumped chunk. */
typedef struct {
  unsigned char *data;
  size_t len;
  size_t cap;
} ljh_buffer;

static int ljh_writer(lua_State *L, const void *p, size_t sz, void *ud)
{
  ljh_buffer *buf = (ljh_buffer *)ud;
  (void)L;
  if (buf->len + sz > buf->cap) {
    size_t want = buf->cap ? buf->cap * 2 : 256;
    unsigned char *grown;
    while (want < buf->len + sz) {
      want *= 2;
    }
    grown = (unsigned char *)realloc(buf->data, want);
    if (grown == NULL) {
      return 0; /* a non-zero return aborts the dump */
    }
    buf->data = grown;
    buf->cap = want;
  }
  memcpy(buf->data + buf->len, p, sz);
  buf->len += sz;
  return 1;
}

/*
** The version symbol, called directly.
**
** `luajit_rolling.h:77` declares `LUAJIT_VERSION_SYM` and `:35` spells it
** `luaJIT_version_2_1_<relver>`, with `<relver>` substituted by
** `genversion.lua`. Calling it turns "this header names a symbol the archive
** does not define" into a link error instead of a run-time surprise, which is
** upstream's stated purpose for it (`luajit_rolling.h:76`).
*/
void ljh_check_version_symbol(void)
{
  LUAJIT_VERSION_SYM();
  ljh_check("LUAJIT_VERSION_SYM links against the archive", 1, LUAJIT_VERSION);
}

/* Every check below runs in its own state. */
void ljh_run_all(void)
{
  int status = 0;
  double value;

  ljh_check_version_symbol();

  /* 1 + 2 * 3 is 7 under any reading of the grammar. */
  value = ljh_run("return 1 + 2 * 3", &status);
  ljh_check("chunk returns 1 + 2 * 3 = 7", status == 0 && value == 7.0, "chunk");

  /*
  ** A hot loop, so the trace recorder has a back-edge to record.
  **
  ** The sum of 1..100 is 5050 by the closed form n(n+1)/2, which is an
  ** independent arithmetic fact rather than anything the interpreter reported.
  */
  value = ljh_run(
      "local s = 0 "
      "for i = 1, 100 do s = s + i end "
      "return s",
      &status);
  ljh_check("loop sums 1..100 to 5050", status == 0 && value == 5050.0, "n(n+1)/2");

  /* `#'ABC'` is 3: the string library's `upper` is unchanged across Lua versions. */
  value = ljh_run("return #('abc':upper())", &status);
  ljh_check("string library upper() gives length 3", status == 0 && value == 3.0, "#'ABC'");

  /* `math.floor` truncates in Lua 5.1, so 3.7 becomes 3. */
  value = ljh_run("return math.floor(3.7)", &status);
  ljh_check("math.floor(3.7) is 3", status == 0 && value == 3.0, "truncation");

  /* A syntax error must reach the pcall boundary as a non-zero status. */
  (void)ljh_run("return 1 +", &status);
  ljh_check("a syntax error fails the chunk", status != 0, "luaL_dostring status");

  /* A runtime error likewise. */
  (void)ljh_run("error('deliberate')", &status);
  ljh_check("a runtime error fails the chunk", status != 0, "luaL_dostring status");

  /* `%.14g` is `LUA_NUMBER_FMT` (`luaconf.h:122`). Comparing the printed text
  ** rather than the double checks the formatting path, which a numeric compare
  ** of the same value would not. */
  {
    lua_State *L = luaL_newstate();
    char buf[64];
    if (L == NULL) {
      ljh_check("1/3 prints as %.14g", 0, "luaL_newstate returned NULL");
    } else {
      luaL_openlibs(L);
      lua_pushnumber(L, 1.0 / 3.0);
      snprintf(buf, sizeof(buf), "%.14g", (double)lua_tonumber(L, -1));
      ljh_check("1/3 prints as %.14g", strcmp(buf, "0.33333333333333") == 0, buf);
      lua_close(L);
    }
  }

  /*
  ** Bytecode round-trip through the C API: `lua_dump` writes the chunk on top of
  ** a state and `luaL_loadbuffer` reads it back into another one.
  **
  ** The generator writes two numbers and the loader multiplies them, so the
  ** value 42 after the round trip means the dumped chunk carried its bytecode
  ** *and* the loader understood it. A build whose bytecode tables disagreed with
  ** its reader fails here rather than at some consumer's load.
  */
  {
    lua_State *writer = luaL_newstate();
    lua_State *reader = luaL_newstate();
    ljh_buffer buf;

    buf.data = NULL;
    buf.len = 0;
    buf.cap = 0;

    if (writer == NULL || reader == NULL) {
      ljh_check("bytecode round-trip through lua_dump", 0, "luaL_newstate returned NULL");
    } else {
      int dump_status;
      int call_status;

      luaL_openlibs(writer);
      luaL_openlibs(reader);

      /* `luaL_loadstring` leaves the compiled chunk on the writer's stack. */
      dump_status = luaL_loadstring(writer, "local a, b = ... ; return a * b");
      if (dump_status != 0) {
        ljh_check("bytecode round-trip through lua_dump", 0, "luaL_loadstring failed");
      } else {
        dump_status = lua_dump(writer, ljh_writer, &buf);
        lua_pop(writer, 1);

        if (dump_status != 0 || buf.len == 0) {
          ljh_check("bytecode round-trip through lua_dump", 0, "lua_dump produced nothing");
        } else {
          char detail[64];
          snprintf(detail, sizeof(detail), "%lu bytes", (unsigned long)buf.len);
          ljh_check("lua_dump produced a chunk", 1, detail);

          call_status = luaL_loadbuffer(reader, (const char *)buf.data, buf.len, "=dumped");
          if (call_status != 0) {
            ljh_check("luaL_loadbuffer read the dumped chunk", 0, "load failed");
          } else {
            lua_pushnumber(reader, 6);
            lua_pushnumber(reader, 7);
            call_status = lua_pcall(reader, 2, 1, 0);
            if (call_status != 0) {
              ljh_check("luaL_loadbuffer read the dumped chunk", 0, "pcall failed");
            } else {
              double product = lua_tonumber(reader, -1);
              lua_pop(reader, 1);
              ljh_check("the dumped chunk reloads and runs", product == 42.0, "6 * 7");
            }
          }
        }
      }
      free(buf.data);
    }

    if (writer != NULL) lua_close(writer);
    if (reader != NULL) lua_close(reader);
  }
}