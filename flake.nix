{
  description = "nix wrap - Easy application sandboxing";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs, ... }:
    let
      pkgs = nixpkgs.legacyPackages."x86_64-linux";

    in
    {
      lib = import ./lib.nix { inherit pkgs; };

      packages = {
        wrap = pkgs.callPackage ./package.nix { };
        default = self.packages."x86_64-linux".wrap;
      };
    };
}
