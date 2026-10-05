# Entry points for `nix build`, plus a portable development shell.
#
# Both packages come from one file, `package.nix`, which is also what
# `devenv.nix` calls. This flake adds no build logic: it selects a nixpkgs,
# names the two delivery variants, and exposes a tools-only shell.
#
# Two conventions worth stating rather than leaving implicit:
#
#   * `packages.<system>.default` is the **static** variant, because that is this
#     SDK's linkage policy. `shared` is a second variant of the same SDK, not a
#     second SDK: one build graph, one module name, one typed surface, and the
#     choice is the library artifact, not the interface. Build them with
#     `nix build .#static` and `nix build .#shared`.
#   * The development shell holds **tools**, never the SDK package itself.
#     Adding the package here would require building the whole library merely
#     to enter the shell. `devenv shell` is the canonical way to work in this
#     repository; this shell exists so the tree is usable from a plain flake
#     checkout, and `nix develop` is not claimed to have been run.
#
# `flake.lock` is generated and owned by the driver. This file pins the nixpkgs
# revision it wants so that the lock records that revision rather than whatever
# a channel happened to be on the day it was written.
#
# Nothing here was evaluated, built or run to produce this file. Every
# packaging statement in README.md and README.zig.md is PENDING-VERIFICATION
# until the driver runs it.

{
  description = "LuaJIT 2.1 rolling: a JIT compiler for Lua 5.1, built from this repository's own source";

  inputs = {
    # Pinned by revision, not by branch. This is the tree that exposes
    # `zig_0_16`, and the revision is the same one `devenv.yaml` names.
    nixpkgs.url = "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";
  };

  outputs =
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      forAllSystems = f: lib.genAttrs lib.systems.flakeExposed (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        # `zig` is named at both call sites: callPackage would otherwise fill it
        # from `pkgs.zig`, a moving alias, rather than the pinned 0.16.0.
        static = pkgs.callPackage ./package.nix {
          zig = pkgs.zig_0_16;
          linkage = "static";
        };
        shared = pkgs.callPackage ./package.nix {
          zig = pkgs.zig_0_16;
          linkage = "dynamic";
        };
        default = static;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          # Tools only. The Zig version is asserted rather than assumed, because
          # `build.zig.zon` declares `.minimum_zig_version = "0.16.0"` and a
          # shell that silently carried another release would make that a
          # statement about nothing.
          packages = [
            (
              assert pkgs.zig_0_16.version == "0.16.0";
              pkgs.zig_0_16
            )
            pkgs.pkg-config
            pkgs.git
          ];
        };
      });
    };
}