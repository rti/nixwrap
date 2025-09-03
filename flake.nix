{
  description = "nixwrap - Easy application sandboxing";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.systems.url = "github:nix-systems/default";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.flake-utils.inputs.systems.follows = "systems";

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      # TODO: explicitly define linux systems, not darwin
      system:

      let
        pkgs = nixpkgs.legacyPackages.${system};

      in
      rec {
        packages = rec {
          wrap = pkgs.callPackage ./package.nix { };
          default = wrap;
        };

        lib = import ./lib.nix {
          inherit pkgs;
        };

        devShells.default = import ./shell.nix {
          inherit pkgs;
        };

        checks.default = import ./tests.nix {
          inherit pkgs;
          inherit (packages) wrap;
        };

      }
    );
}
