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

        lib = import ./lib.nix { inherit pkgs; };

        packages = rec {
          wrap = pkgs.callPackage ./package.nix { };
          default = wrap;
        };

        devShells.default = import ./shell.nix { inherit pkgs; };

        checks =
          let
            wrap-bin = "${packages.wrap}/bin/wrap";
            bash-bin = "${pkgs.bash}/bin/bash";

            tests = [
              {
                name = "env-home-is-always-exposed";
                test = ''HOME=/homedir ${wrap-bin} ${bash-bin} -c 'echo $HOME' | grep homedir > $out'';
              }
              {
                name = "env-editor-is-always-exposed";
                test = ''EDITOR=myeditor ${wrap-bin} ${bash-bin} -c 'echo $EDITOR' | grep myeditor > $out'';
              }
              {
                name = "user-name-is-hidden";
                test = ''
                  ${wrap-bin} whoami 2> error-msg || true
                  cat error-msg | grep "cannot find name for user ID" > $out
                '';
              }
              {
                name = "u-exposes-user-name";
                test = ''${wrap-bin} -u whoami > $out'';
              }
              {
                name = "env-wayland-display-is-hidden";
                test = ''
                  WAYLAND_DISPLAY=wl-0 ${wrap-bin} ${bash-bin} -c 'set -u; echo $WAYLAND_DISPLAY' 2> error-msg || true
                  cat error-msg | grep "WAYLAND_DISPLAY: unbound variable" > $out
                '';
              }
              {
                name = "d-exposes-env-wayland-display";
                test = ''
                  export XDG_RUNTIME_DIR="/tmp"
                  export WAYLAND_DISPLAY="wl-0"
                  mkdir -p $XDG_RUNTIME_DIR
                  touch $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY
                  ${wrap-bin} -d ${bash-bin} -c 'echo $WAYLAND_DISPLAY' | grep wl-0 > $out
                '';
              }
              {
                name = "d-exposes-env-x11-display";
                test = ''
                  export DISPLAY=":0"
                  ${wrap-bin} -d ${bash-bin} -c 'echo $DISPLAY' | grep ":0" > $out
                '';
              }
              {
                name = "d-exposes-socket-x11";
                test = ''
                  mkdir -p /tmp/.X11-unix
                  touch /tmp/.X11-unix/X12345
                  export DISPLAY=":12345"
                  ${wrap-bin} -d ${bash-bin} -c 'ls /tmp/.X11-unix/X12345' > $out
                  rm /tmp/.X11-unix/X12345
                '';
              }
              {
                name = "d-exposes-xauthority";
                test = ''
                  export DISPLAY=":12345"
                  export HOME=/tmp/home
                  mkdir -p $HOME
                  touch $HOME/.Xauthority
                  ${wrap-bin} -d ${bash-bin} -c 'cat $HOME/.Xauthority' > $out
                '';
              }
              {
                name = "d-exposes-custom-xauthority";
                test = ''
                  export DISPLAY=":12345"
                  export XAUTHORITY="myxauthfile"
                  export HOME=/tmp/home
                  mkdir -p $HOME
                  touch $HOME/$XAUTHORITY
                  ${wrap-bin} -d ${bash-bin} -c 'cat $HOME/.Xauthority' > $out
                '';
              }
              {
                name = "r-exposes-path-readonly";
                test = ''
                  mkdir -p /tmp/some-dir
                  echo "file-content" > /tmp/some-dir/test-file
                  ${wrap-bin} -r /tmp/some-dir ${bash-bin} -c 'cat /tmp/some-dir/test-file' | grep "file-content"
                  ${wrap-bin} -r /tmp/some-dir ${bash-bin} -c 'echo more >> /tmp/some-dir/test-file' 2> error-msg || true
                  cat error-msg | grep "/tmp/some-dir/test-file: Read-only file system" > $out
                '';
              }
              {
                name = "w-exposes-path-readwrite";
                test = ''
                  mkdir -p /tmp/some-dir
                  echo "file-content" > /tmp/some-dir/test-file
                  ${wrap-bin} -w /tmp/some-dir ${bash-bin} -c 'cat /tmp/some-dir/test-file' | grep "file-content"
                  ${wrap-bin} -w /tmp/some-dir ${bash-bin} -c 'echo more >> /tmp/some-dir/test-file'
                  cat /tmp/some-dir/test-file | grep "more" > $out
                '';
              }
            ];
          in
          builtins.listToAttrs (
            map (t: {
              name = t.name;
              value = pkgs.runCommand t.name { } t.test;
            }) tests
          );
      }
    );
}
