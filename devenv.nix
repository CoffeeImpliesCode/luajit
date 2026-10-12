# The canonical development shell for this SDK.
#
# Enter it with `devenv shell`, or let direnv do it through `.envrc`.
#
# Four rules shape this file and none of them is negotiable:
#
#   * The SDK package is NOT in `packages`. Listing it would mean building the
#     whole native library merely to enter the shell. `packages` holds tools
#     only. The library is built on demand - `zig build` from the source tree,
#     or `devenv build outputs.static` for the packaging route.
#   * `outputs.static`, `outputs.shared` and `outputs.default` are **lazy**:
#     they are the same `pkgs.callPackage ./package.nix` derivation `flake.nix`
#     builds, and nothing in this file forces them to be realised. `devenv build
#     outputs.static` is the real packaging command; it is a build, not a shell
#     entry.
#   * No host path, user name, store path or node path appears anywhere in this
#     file, and nothing is read from the environment at evaluation time. No
#     `builtins.getEnv`, no `builtins.currentSystem`.
#   * Scratch and cache are the caller's business, and nothing in this file
#     writes into this checkout. A directory the caller already exported always
#     wins and is never overwritten; a task that generates output fills a
#     missing `ZIG_LOCAL_CACHE_DIR` from `XDG_CACHE_HOME`, then from `TMPDIR`,
#     and refuses to run when neither is set rather than choosing a location of
#     its own. `TMPDIR`, `DEVENV_HOME`, `XDG_RUNTIME_DIR` and the rest are
#     never unset. A receipt meant to be recorded belongs in an approved-scratch
#     run that supplied them.
#
# Nothing here was evaluated, built or run to produce this file.

{ pkgs, lib, inputs, ... }:

let
  # Keep the devenv bootstrap package set separate from the pinned compiler.
  zigPkgs = import inputs.nixpkgs-unstable { system = pkgs.stdenv.hostPlatform.system; };
  zig = zigPkgs.zig_0_17;

  # One derivation, two variants. `package.nix` is the whole build; these
  # attribute values are only forced when someone asks for the output.
  luajit = linkage: pkgs.callPackage ./package.nix { inherit zig linkage; };

  # This module's own directory, shell-quoted once for every task body below.
  #
  # `./.` in an expression is relative to the file that contains it, so this is
  # the SDK root however devenv was invoked, and a task body that has to be
  # here says so itself instead of trusting the caller's directory or
  # `$DEVENV_ROOT` - which is the devenv *project*, holding `.devenv/` and
  # `devenv.lock` and neither `build.zig` nor `UPSTREAM.sha256`. It is
  # `builtins.toString` and not `"${./.}"` deliberately: interpolating a path
  # copies it into the read-only Nix store, which here would be a frozen second
  # copy of the whole SDK rather than the working tree `build.zig` and
  # `UPSTREAM.sha256` describe. No host path is written in this file - the value
  # is read out of the module's own location, so it tracks this checkout.
  sdk_root = lib.escapeShellArg (builtins.toString ./.);

  # Where a task's build output goes. `zig build` keeps its local cache in
  # `.zig-cache/` and installs into `zig-out/`, both relative to the working
  # directory, and this checkout is a working tree that has to stay
  # byte-identical.
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

  # The same rule with the one extra requirement a task that generates output
  # has: it must be able to name that directory. An environment with nowhere
  # outside the checkout to write stops here, with the reason, instead of
  # filling the tree.
  require_external_output = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      echo "luajit devenv: ZIG_LOCAL_CACHE_DIR, XDG_CACHE_HOME and TMPDIR are all unset," >&2
      echo "so there is nowhere outside this checkout to put build output." >&2
      echo "Export one of them at approved scratch, then run the task again." >&2
      exit 1
    fi
  '';

  # What a task that only reads this tree starts with. devenv materialises a
  # task as a generated shell program that inherits the caller's working
  # directory. The `exit 1` is not decoration: a `cd` that failed and was not
  # checked would run the rest of the body wherever the caller stood.
  in_sdk = ''
    cd ${sdk_root} || exit 1
  '';

  # What a task that builds adds to that: the two cache directories, filled by
  # the rule above, and the refusal when there is nowhere external to write.
  in_sdk_build = ''
    ${zig_caches}
    ${require_external_output}
    ${in_sdk}
  '';

  # The flags every `zig build` here shares: this workspace's eight jobs,
  # fixed, then the printed step list and a cache outside the checkout. No
  # caller flags are forwarded and none were before - `devenv tasks run` takes
  # no argument of its own, so a task body has nothing to forward.
  build_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/native"
  '';

  # The one prefix this SDK's `zig build install` writes to. Both that step and
  # the default step install, so without `--prefix` the delivery tree would be
  # created inside the checkout. The steps that install nothing - `test`,
  # `smoke`, `check`, `consumer`, which `build.zig:393,402,409,417` wires to no
  # install step - get no prefix they could not use.
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
    # This SDK's linkage policy is static, so `default` follows it.
    default = luajit "static";
  };

  tasks = {
    # Every body below changes into this SDK's own directory first and then keeps
    # what it generates outside the checkout: `build_flags` fixes the job count
    # at this workspace's eight and names a cache in the caller's local cache
    # directory, and the two entries that install also name an external prefix.
    # Task names, steps and order are exactly what they were.
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
      description = "the same suite in safe mode";
      exec = ''
        ${in_sdk_build}
        zig build test -Doptimize=safe ${build_flags}
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
        zig build test -Doptimize=safe ${build_flags}
        zig build smoke ${build_flags}
        zig build check ${build_flags}
        zig build consumer ${build_flags}
        sha256sum -c UPSTREAM.sha256
      '';
    };
  };

  # The shell hook fills the same two cache directories the tasks use, by the
  # same rule, so an ordinary `devenv shell` session leaves this checkout alone
  # as well. A value the caller exported is kept exactly as it is, and with
  # nothing to choose from the hook chooses nothing: only a task, which has to
  # name the directory, refuses.
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
        lib.assertMsg (zig.version == "0.17.0")
          "this SDK builds with Zig 0.17.0; devenv resolved ${zig.version}";
      message = "luajit needs Zig 0.17.0.";
    }
  ];
}