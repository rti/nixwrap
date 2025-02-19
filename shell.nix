{
  pkgs ? import <nixpkgs>,
}:
pkgs.mkShell {
  buildInputs = [
    pkgs.bubblewrap

    (pkgs.callPackage ./package.nix { })

    (pkgs.writeShellScriptBin "format" ''
      set -xe
      ${pkgs.nixfmt-rfc-style}/bin/nixfmt *.nix
      ${pkgs.shfmt}/bin/shfmt --indent 2 --write *.sh
    '')
  ];
}
