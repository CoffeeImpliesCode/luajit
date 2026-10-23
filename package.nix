# Nix wrapper around the Zig build and install steps.
# `linkage` selects the library artifact; `static` is the default.

{
  lib,
  stdenv,
  # Pin the package to Zig 0.16.0, not nixpkgs' moving `zig` alias.
  zig,
  # Used to verify the installed pkg-config metadata.
  pkg-config,
  linkage ? "static",
  optimize ? "ReleaseFast",
}:

assert lib.assertMsg (zig.version == "0.16.0")
  "LuaJIT builds with Zig 0.16.0; this derivation was given zig ${zig.version}";
assert lib.assertMsg (linkage == "static" || linkage == "dynamic")
  "linkage must be \"static\" or \"dynamic\", not ${lib.strings.toString linkage}";
# Nix cross builds are unsupported; target selection belongs to build.zig.
assert lib.assertMsg (stdenv.hostPlatform.system == stdenv.buildPlatform.system)
  "package.nix builds LuaJIT for the build platform only; cross-compiling it from Nix is not supported";

stdenv.mkDerivation (finalAttrs: {
  pname = "luajit";
  # Rolling upstream version derived from the checked-in `.relver` stamp.
  version = "2.1.1788856981";

  src = lib.cleanSourceWith {
    src = ./.;
    # Filter build debris without changing the package's `.paths` allowlist.
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
      # Exclude Nix result symlinks.
      && name != "result"
      && !(lib.hasPrefix "result-" name);
  };

  strictDeps = true;

  nativeBuildInputs = [
    zig
    pkg-config
  ];

  # Run Zig's install step with the build flags below.
  dontConfigure = true;
  dontBuild = true;
  dontCheck = true;
  # Prevent the Zig hook from adding a differently flagged check build.
  dontUseZigCheck = true;
  # Supply Zig flags and prefix explicitly below.
  dontSetZigDefaultFlags = true;
  dontAddPrefix = true;

  installPhase = ''
    runHook preInstall

    # Keep Zig caches in writable scratch, outside the source tree.
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

  # Let `zig build install` own the complete installed tree.

  # Require pkg-config metadata in the output.
  postFixup = ''
    test -f "$out/lib/pkgconfig/luajit.pc"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    export PKG_CONFIG_PATH="$out/lib/pkgconfig"

    test "$(pkg-config --modversion luajit)" = "${finalAttrs.version}"

    for header in lua.h lualib.h lauxlib.h luaconf.h lua.hpp luajit.h; do
      test -f "$out/include/luajit-2.1/$header"
    done

    if [ "${linkage}" = static ]; then
      test -f "$out/lib/libluajit-5.1.a"
    else
      ls "$out/lib/"libluajit-5.1.so* > /dev/null
    fi

    test -f "$out/share/luajit-2.1/jit/bc.lua"
    test -f "$out/share/luajit-2.1/jit/vmdef.lua"

    # Verify the licence and provenance records installed by build.zig.
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
    # Nix license metadata is a summary; NOTICE.md records per-file terms.
    license = lib.licenses.mit;
    licenseFile = "COPYRIGHT";
    # Windows outputs are not claimed by this derivation.
    platforms = lib.platforms.unix;
  };

  passthru = {
    inherit linkage optimize;

    # Exported rolling-version ABI symbol.
    abiIdentitySymbol = "luaJIT_version_2_1_1788856981";
  };
})