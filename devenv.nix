# LuaJIT development shell and build tasks.
# Build outputs and Zig caches stay outside this checkout.

{ pkgs, lib, ... }:

let
  # Pin the toolchain used by this package.
  zig = pkgs.zig_0_16;

  luajit = linkage: pkgs.callPackage ./package.nix { inherit zig linkage; };

  # Resolve this checkout without copying it into the Nix store; tasks cd here
  # rather than relying on `DEVENV_ROOT` or the caller's working directory.
  sdk_root = lib.escapeShellArg (builtins.toString ./.);

  # Keep Zig caches and build outputs outside the checkout.
  zig_caches = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        export ZIG_LOCAL_CACHE_DIR="$XDG_CACHE_HOME/luajit/zig-local-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        export ZIG_LOCAL_CACHE_DIR="$TMPDIR/luajit/zig-local-cache"
      fi
    fi
    if [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        export ZIG_GLOBAL_CACHE_DIR="$XDG_CACHE_HOME/luajit/zig-global-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/luajit/zig-global-cache"
      fi
    fi
    if [ -n "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      mkdir -p "$ZIG_LOCAL_CACHE_DIR"
    fi
    if [ -n "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    fi
  '';

  # Refuse output-producing tasks when no external cache directory is available.
  require_external_output = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      echo "luajit devenv: ZIG_LOCAL_CACHE_DIR, XDG_CACHE_HOME and TMPDIR are all unset," >&2
      echo "so there is nowhere outside this checkout to put build output." >&2
      echo "Export one of them at approved scratch, then run the task again." >&2
      exit 1
    fi
  '';

  # Task bodies must enter the checkout and stop if that fails.
  in_sdk = ''
    cd ${sdk_root} || exit 1
  '';

  # Build tasks use the external caches and prefix.
  in_sdk_build = ''
    ${zig_caches}
    ${require_external_output}
    ${in_sdk}
  '';

  # Use a fixed job width and external cache for build tasks.
  build_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/native"
  '';

  # Install outputs outside the source checkout.
  install_prefix = "$ZIG_LOCAL_CACHE_DIR/prefix";
in
{
  packages = [
    zig
    pkgs.pkg-config
    pkgs.git
  ];

  outputs = {
    static = luajit "static";
    shared = luajit "dynamic";
    # The default output follows this SDK's static linkage policy.
    default = luajit "static";
  };

  tasks = {
    # Tasks run from the SDK root and keep generated output outside it.
    "sdk:build" = {
      description = "zig build install - compile the library and install it under $ZIG_LOCAL_CACHE_DIR/prefix";
      exec = ''
        ${in_sdk_build}
        zig build install --prefix "${install_prefix}" ${build_flags}
      '';
    };

    "sdk:test" = {
      description = "zig build test - the behavioural test suite";
      exec = ''
        ${in_sdk_build}
        zig build test ${build_flags}
      '';
    };

    "sdk:test-release-safe" = {
      description = "the same suite in ReleaseSafe";
      exec = ''
        ${in_sdk_build}
        zig build test -Doptimize=ReleaseSafe ${build_flags}
      '';
    };

    "sdk:smoke" = {
      description = "zig build smoke - the deterministic example program";
      exec = ''
        ${in_sdk_build}
        zig build smoke ${build_flags}
      '';
    };

    "sdk:check" = {
      description = "zig build check - compile-only over the six baseline targets";
      exec = ''
        ${in_sdk_build}
        zig build check ${build_flags}
      '';
    };

    "sdk:consumer" = {
      description = "zig build consumer - the separate dependent package";
      exec = ''
        ${in_sdk_build}
        zig build consumer ${build_flags}
      '';
    };

    "sdk:integrity" = {
      description = "sha256sum -c UPSTREAM.sha256 - every shipped upstream file";
      exec = ''
        ${in_sdk}
        sha256sum -c UPSTREAM.sha256
      '';
    };

    "sdk:gate" = {
      description = "every source-tree gate above, in order";
      exec = ''
        set -e
        ${in_sdk_build}
        zig build install --prefix "${install_prefix}" ${build_flags}
        zig build test ${build_flags}
        zig build test -Doptimize=ReleaseSafe ${build_flags}
        zig build smoke ${build_flags}
        zig build check ${build_flags}
        zig build consumer ${build_flags}
        sha256sum -c UPSTREAM.sha256
      '';
    };
  };

  # The shell applies the same external-cache rule as build tasks.
  enterShell = ''
    ${zig_caches}
    echo "luajit 2.1.1788856981 (pinned c6ffc141a8762b41703f9287d63d93622a13dd8f), Lua 5.1 ABI, GC64 on 64-bit targets"
    echo "README.md is this fork's; upstream's is README.upstream.md. NOTICE.md is the licence audit."
    echo "source tree:   devenv tasks run sdk:build | sdk:test | sdk:test-release-safe | sdk:smoke | sdk:check | sdk:consumer | sdk:integrity | sdk:gate"
    echo "packaging:     devenv build outputs.static | outputs.shared   (both build package.nix)"
    echo "cache:         $ZIG_LOCAL_CACHE_DIR/native, $ZIG_LOCAL_CACHE_DIR/prefix   (a task builds under neither ./zig-out nor ./.zig-cache)"
  '';

  assertions = [
    {
      assertion =
        lib.assertMsg (zig.version == "0.16.0")
          "this SDK builds with Zig 0.16.0; devenv resolved ${zig.version}";
      message = "luajit needs Zig 0.16.0.";
    }
  ];
}