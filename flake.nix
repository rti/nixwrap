{
  description = "nixwrap - Easy application sandboxing";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.systems.url = "github:nix-systems/default";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.flake-utils.inputs.systems.follows = "systems";

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        lib = import ./lib.nix { inherit nixpkgs; };
        packages = rec {
          wrap = pkgs.callPackage ./package.nix { };
          default = wrap;
        };
        devShells.default = import ./shell.nix { inherit pkgs; };
      }
    );
}
