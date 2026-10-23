# Nix entry points for static and shared variants, plus a tools-only shell.

{
  description = "LuaJIT 2.1 rolling: a JIT compiler for Lua 5.1, built from this repository's own source";

  inputs = {
    # Keep the nixpkgs revision aligned with devenv.yaml.
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
        # Use the pinned Zig 0.16.0 package instead of nixpkgs' moving alias.
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
          # Keep the shell toolchain at Zig 0.16.0.
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