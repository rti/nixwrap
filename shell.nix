{ pkgs }:
pkgs.mkShell {
  buildInputs = [
    pkgs.bubblewrap

    (pkgs.callPackage ./package.nix { })

    (pkgs.writeShellScriptBin "format" ''
      set -xe
      ${pkgs.nixfmt}/bin/nixfmt *.nix examples/*.nix
      ${pkgs.shfmt}/bin/shfmt --indent 2 --write *.sh
    '')
  ];

  shellHook = ''
    ${pkgs.figlet}/bin/figlet "nixwrap"
  '';
}
