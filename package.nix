# LuaJIT as a Nix package.
#
# One standalone, source-only derivation. `flake.nix` and `devenv.nix` both
# reach it through `pkgs.callPackage`; neither reimplements it.
#
#   * The source is this directory: no `fetchurl`, no `fetchgit`, no
#     build-time download and no sibling-workspace path. The pinned tree is
#     already here, `.relver` included, and the rolling version string is
#     generated from it exactly the way upstream generates it.
#   * The native C is compiled by `build.zig`, not by Nix. The library closure,
#     the host generators (`buildvm`, `minilua`, `genminilua`, `genlibbc`,
#     `genversion`), the back-end selection, the export macros and the installed
#     file list are the build graph's business. This file restates none of them
#     and passes no C flag of its own.
#   * `static` means a static *library artifact*. It is not a promise that a
#     program linked against it is wholly static, on any target.
#   * No host account name, home directory, node or store path appears here,
#     and nothing is read from the environment at evaluation time.
#
# `linkage` selects the build graph's own delivery mode. `static` is the
# default because that is this SDK's linkage policy: the build graph produced a
# static archive only until `-Dlinkage` was introduced. The two are package
# variants of one SDK, not two modules.

{
  lib,
  stdenv,
  # `zig` is injected, not defaulted: both entry points name pkgs.zig_0_16 out
  # loud, so a nixpkgs bump cannot move this SDK off 0.16.0 by way of the
  # moving `pkgs.zig` alias.
  zig,
  # Read by `installCheckPhase` to resolve the metadata `build.zig` writes. It
  # is an injected argument rather than a name spelled in the body, which would
  # not be bound.
  pkg-config,
  linkage ? "static",
  optimize ? "ReleaseFast",
}:

assert lib.assertMsg (zig.version == "0.16.0")
  "LuaJIT builds with Zig 0.16.0; this derivation was given zig ${zig.version}";
assert lib.assertMsg (linkage == "static" || linkage == "dynamic")
  "linkage must be \"static\" or \"dynamic\", not ${lib.strings.toString linkage}";
# A Nix cross derivation would have to tell the build graph which target to
# compile for, and that mapping is the build graph's decision, not this file's.
# Rather than guess it, this derivation builds natively. That still covers a
# remote builder: on a remote builder `buildPlatform` and `hostPlatform` are
# the same system even though the machine is a different one.
assert lib.assertMsg (stdenv.hostPlatform.system == stdenv.buildPlatform.system)
  "package.nix builds LuaJIT for the build platform only; cross-compiling it from Nix is not supported";

stdenv.mkDerivation (finalAttrs: {
  pname = "luajit";
  # Upstream's own version, derived the way upstream derives it:
  # `Makefile:16-26` computes `$(MAJVER).$(MINVER).$(RELVER)` and
  # `src/Makefile:495` reads RELVER from `git show -s --format=%ct` or, with no
  # `.git` directory present, from this repository's committed `.relver`,
  # which holds 1788856981 - the pinned commit's Unix timestamp,
  # 2026-09-08T08:43:01Z. `src/host/genversion.lua` writes that number into the
  # generated `src/luajit.h`, so the header a consumer compiles against says
  # "LuaJIT 2.1.1788856981" and exports `luaJIT_version_2_1_1788856981`.
  # `build.zig.zon` carries the same string.
  version = "2.1.1788856981";

  src = lib.cleanSourceWith {
    src = ./.;
    # Build debris and tool state, named rather than pattern-matched, so that a
    # derivation never copies a cache into the store and so that no source file
    # is dropped by a pattern this file would have to keep in step with. The
    # allowlist of what the package publishes is `build.zig.zon`'s `.paths`; the
    # two answer different questions.
    filter = path: _type:
      let name = baseNameOf (toString path);
      in !(builtins.elem name [
        ".git"
        ".jj"
        ".devenv"
        ".devenv.flake.nix"
        ".direnv"
        ".zig-cache"
        "zig-cache"
        "__pycache__"
        "zig-out"
        "zig-pkg"
      ])
      # A `result` symlink, and the `result-<variant>` links `nix build` leaves
      # beside it, are Nix build outputs rather than source files.
      && name != "result"
      && !(lib.hasPrefix "result-" name);
  };

  strictDeps = true;

  nativeBuildInputs = [
    zig
    pkg-config
  ];

  # `zig build install` is the whole build. It compiles the library closure,
  # runs upstream's own host generators for the target, assembles the VM from
  # the selected back end, and writes the installed prefix. There is nothing to
  # configure: no autotools, no `make`, no `src/Makefile`, no configure script,
  # no downloaded input. An explicit install phase with `dontBuild` keeps the
  # flags below authoritative - the default phase would build with its own.
  dontConfigure = true;
  dontBuild = true;
  dontCheck = true;
  # Without this the Zig setup hook substitutes its own `zig build test` for the
  # check phase, which is a second, differently-flagged build of the same tree.
  # `doInstallCheck` below is unaffected and still runs.
  dontUseZigCheck = true;
  # The hook's own flag set and prefix are suppressed for the same reason: this
  # phase names `-Doptimize`, `-Dcpu`, `-Dlinkage` and `--prefix` once each.
  dontSetZigDefaultFlags = true;
  dontAddPrefix = true;

  installPhase = ''
    runHook preInstall

    # A writable Zig cache inside this build's own TMPDIR, outside the unpacked
    # source tree and outside the store. `zig`'s setup hook also sets one, but
    # naming it here keeps the derivation independent of which phases the hook
    # claims.
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"

    zig build install \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=${optimize} \
      -Dlinkage=${linkage} \
      -Dcpu=baseline

    runHook postInstall
  '';

  # No `postInstall`: `zig build install` is the only writer of every installed
  # path, so `nix build .#static` and `nix build .#shared` deliver exactly what a
  # local `zig build install --prefix …` does, and this derivation contributes
  # nothing but the prefix, the caches and the flags. The install check below
  # asserts each of those paths exists, so a graph that stops installing one
  # fails loudly rather than shipping an output missing its licence text.

  # Link metadata is a deliverable, not an optional extra: a package whose
  # output has no `-lluajit-5.1` to point at is a source drop. The build graph
  # generates it from upstream's own `etc/luajit.pc`, so this derivation fails
  # loudly rather than shipping an output with no way to link it.
  postFixup = ''
    test -f "$out/lib/pkgconfig/luajit.pc"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    export PKG_CONFIG_PATH="$out/lib/pkgconfig"

    # A wrong version in the metadata would silently hand a consumer the wrong
    # LuaJIT, so read it back rather than assert it in prose.
    test "$(pkg-config --modversion luajit)" = "${finalAttrs.version}"

    # The six headers upstream installs, from `Makefile:98`.
    for header in lua.h lualib.h lauxlib.h luaconf.h lua.hpp luajit.h; do
      test -f "$out/include/luajit-2.1/$header"
    done

    # The library the metadata names, in the form this variant installed.
    if [ "${linkage}" = static ]; then
      test -f "$out/lib/libluajit-5.1.a"
    else
      ls "$out/lib/"libluajit-5.1.so* > /dev/null
    fi

    # The runtime modules a `require` needs, from `Makefile:99-104`.
    test -f "$out/share/luajit-2.1/jit/bc.lua"
    test -f "$out/share/luajit-2.1/jit/vmdef.lua"

    # Every licence and provenance file, at the path the build graph installs
    # it. `zig build install` is the only writer of any of these, so these
    # assertions verify the build graph rather than this wrapper.
    test -f "$out/share/doc/luajit-2.1/COPYRIGHT"
    test -f "$out/share/doc/luajit-2.1/README.md"
    licence_dir="$out/share/licenses/${finalAttrs.pname}"
    test -f "$licence_dir/NOTICE.md"
    test -f "$licence_dir/FORK-LICENSE.md"
    test -f "$licence_dir/UPSTREAM.md"
    test -f "$licence_dir/README.upstream.md"

    runHook postInstallCheck
  '';

  meta = {
    description =
      "Just-In-Time compiler for Lua 5.1, production rolling release 2.1.1788856981, built from this repository's own source by Zig 0.16";
    longDescription = ''
      LuaJIT 2.1.1788856981, pinned at commit
      c6ffc141a8762b41703f9287d63d93622a13dd8f and compiled from this
      repository's own src/ by Zig 0.16.0. The release version is not typed
      anywhere in this package: it is the commit timestamp in the committed
      .relver, substituted into src/luajit.h exactly as upstream does.

      This output is not one licence. src/lj_alloc.c is a public-domain
      dlmalloc, src/lj_alloc.h, src/lj_char.c, src/lj_char.h and six console
      build scripts were donated to the public domain, and the tree carries
      Lua.org's own MIT grant over the Lua 5.1 code it includes. Read
      $out/share/licenses/luajit/NOTICE.md before redistributing this output.

      The library is a Lua 5.1 implementation. It is not ABI-compatible with
      Lua 5.4 or later, and nothing here may be substituted for it.
    '';
    homepage = "https://luajit.org/";
    # A summary, not the whole record: upstream's MIT over upstream's files,
    # public-domain donations inside the compiled closure, and this fork's MIT
    # over its own. NOTICE.md is the record that can express all three.
    license = lib.licenses.mit;
    licenseFile = "COPYRIGHT";
    # Unix only, and that is a boundary rather than a verdict. Nothing has
    # produced a `.dll` or a `.lib` from this source yet, so Windows is not
    # claimed rather than being claimed and failing.
    platforms = lib.platforms.unix;
  };

  passthru = {
    # What this derivation was asked for, so a caller can read the variant back
    # without re-deriving it from an attribute path.
    inherit linkage optimize;

    # LuaJIT's rolling-release identity symbol, spelled `LUAJIT_VERSION_SYM`
    # after `src/host/genversion.lua`. It is exported by the library and is
    # what a dynamic linker checks; see UPSTREAM.md.
    abiIdentitySymbol = "luaJIT_version_2_1_1788856981";
  };
})