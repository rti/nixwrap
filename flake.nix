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
      rec {

        lib = import ./lib.nix { inherit nixpkgs; };

        packages = rec {
          wrap = pkgs.callPackage ./package.nix { };
          default = wrap;
        };

        devShells.default = import ./shell.nix { inherit pkgs; };

        checks =
          let
            wrap-bin = "${packages.wrap}/bin/wrap";
            bash-bin = "${pkgs.bash}/bin/bash";
          in
          {
            env-home-is-always-exposed = pkgs.runCommand "env-home-is-always-exposed" { } ''
              HOME=/homedir ${wrap-bin} ${bash-bin} -c 'echo $HOME' | grep homedir > $out
            '';
            env-editor-is-always-exposed = pkgs.runCommand "env-editor-is-always-exposed" { } ''
              EDITOR=myeditor ${wrap-bin} ${bash-bin} -c 'echo $EDITOR' | grep myeditor > $out
            '';
            user-name-is-hidden = pkgs.runCommand "user-name-is-hidden" { } ''
              ${wrap-bin} whoami 2> error-msg || true
              cat error-msg | grep "cannot find name for user ID" > $out
            '';
            user-name-is-exposed = pkgs.runCommand "user-name-is-exposed" { } ''
              ${wrap-bin} -u whoami > $out
            '';
            env-wayland-display-is-hidden = pkgs.runCommand "env-wayland-display-is-hidden" { } ''
              WAYLAND_DISPLAY=wl-0 ${wrap-bin} ${bash-bin} -c 'set -u; echo $WAYLAND_DISPLAY' 2> error-msg || true
              cat error-msg | grep "WAYLAND_DISPLAY: unbound variable" > $out
            '';
            env-wayland-display-is-exposed-with-d = pkgs.runCommand "env-wayland-display-is-exposed-with-d" { } ''
              export XDG_RUNTIME_DIR="/tmp"
              export WAYLAND_DISPLAY="wl-0"
              mkdir -p $XDG_RUNTIME_DIR
              touch $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY
              ${wrap-bin} -d ${bash-bin} -c 'echo $WAYLAND_DISPLAY' | grep wl-0 > $out
            '';
          };
      }
    );
}
