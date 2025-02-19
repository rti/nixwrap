{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.wrap.url = "github:rti/nixwrap";

  outputs = { nixpkgs, wrap, ... } @inputs:
    inputs.flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {

        devShells.default = pkgs.mkShell {
          buildInputs = [
            (wrap.lib.${system}.wrap {
              package = pkgs.nodejs;
              executable = "node";
              wrapArgs = "-n";
            })
          ];
        };
      }
    );
}
