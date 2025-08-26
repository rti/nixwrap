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
              {
                name = "cwd-exposed-by-default";
                test = ''
                  mkdir -p /tmp/some-dir
                  cd /tmp/some-dir
                  echo "file-content" > test-file
                  ${wrap-bin} ${bash-bin} -c 'cat test-file' | grep "file-content" > $out
                '';
              }
              {
                name = "cwd-not-exposed-by-p";
                test = ''
                  mkdir -p /tmp/some-dir
                  cd /tmp/some-dir
                  echo "file-content" > test-file
                  ${wrap-bin} -p ${bash-bin} -c 'cat test-file; echo $?' | grep 1 > $out
                '';
              }
              {
                name = "-p-cds-to-root";
                test = ''
                  mkdir -p /tmp/new-home
                  export HOME=/tmp/new-home
                  ${wrap-bin} -p ${bash-bin} -c 'pwd' | grep / > $out
                '';
              }

              {
                name = "cwd not shared implicitly for home directories";
                test =
                  # setup prerequisites
                  ''
                    # Setup a home directory and put something in. We expect
                    # this to NOT be visible in the sandbox because it was not
                    # shared explicitly and home directories are expluded from
                    # implicit sharing.
                    mkdir -p /tmp/new-home
                    export HOME=/tmp/new-home
                    touch /tmp/new-home/something-in-home

                    # Make the home directory the cwd
                    cd $HOME
                  '' +

                  # prerequisite checks
                  ''
                    pwd | grep '^/tmp/new-home$' \
                      || (echo 'Unexpected: Home directory is not cwd outside sandbox'; false)

                    ls -l /tmp | grep '[[:space:]]new-home$' \
                      || (echo 'Unexpected: Home directory outside sandbox not found'; false)

                    ls -l $HOME | grep '[[:space:]]something-in-home$' \
                      || (echo 'Unexpected: File in $HOME outside sandbox not found'; false)
                  '' +

                  # test
                  ''
                    # expect the cwd to be /, because $HOME as cwd is excluded from implicit sharing
                    ${wrap-bin} ${bash-bin} -c 'pwd' | grep '^/$' \
                      || (echo 'Unexpected: Cwd in sandbox is not /'; false)

                    ${wrap-bin} ${bash-bin} -c 'ls -l $HOME' | grep '^total 0$' \
                      || (echo 'Unexpected: Sandbox $HOME is not empty'; false)

                    echo 'test-success' > $out
                  '';
              }

              {
                name = "parameter -f forces to share the cwd $HOME, even though it is excluded from sharing as cwd implicitly";
                test =
                  # setup prerequisites
                  ''
                    # Setup a home directory and put something in. We expect
                    # this to be visible in the sandbox because it was shared
                    # explicitly implicit sharing.
                    mkdir -p /tmp/new-home
                    export HOME=/tmp/new-home
                    touch /tmp/new-home/something-in-home

                    # Make the home directory the cwd
                    cd $HOME
                  '' +

                  # prerequisite checks
                  ''
                    pwd | grep '^/tmp/new-home$' \
                      || (echo 'Unexpected: Home directory is not cwd outside sandbox'; false)

                    ls -l /tmp | grep '[[:space:]]new-home$' \
                      || (echo 'Unexpected: Home directory outside sandbox not found'; false)

                    ls -l $HOME | grep '[[:space:]]something-in-home$' \
                      || (echo 'Unexpected: File in $HOME outside sandbox not found'; false)
                  '' +

                  # test
                  ''
                    # expect the cwd to be $HOME
                    ${wrap-bin} -f ${bash-bin} -c 'pwd' | grep '^/tmp/new-home$' \
                      || (echo 'Unexpected: Cwd in sandbox is not $HOME'; false)

                    ${wrap-bin} -f ${bash-bin} -c 'ls $HOME' | grep '^something-in-home$' \
                      || (echo 'Unexpected: Sandbox $HOME is empty'; false)

                    echo 'test-success' > $out
                  '';
              }

              {
                name = "parameter -f forces to share the cwd /, even though it is excluded from sharing as cwd implicitly";
                test =
                  # setup prerequisits
                  ''
                    # / is a directory expluded from implicit cwd sharing
                    cd /
                  '' +
                  # prerequisit checks
                  ''
                    pwd | grep "^/$" \
                      || (echo 'Unexpected: Cwd to be / outside sandbox'; false)
                    ls -l | grep "[[:space:]]bin$" \
                      || (echo 'Unexpected: Bin dir is missing in / outside sandbox'; false)
                  '' +
                  # test
                  ''
                    ${wrap-bin} -f ${bash-bin} -c 'pwd' | grep '^/$' 2> /dev/null \
                      || (echo 'Unexpected: Cwd in sandbox is not /'; false)
                    ${wrap-bin} -f ${bash-bin} -c 'ls -l' | grep 'bin$' 2> /dev/null \
                      || (echo 'Unexpected: Bin dir not in / inside sandbox'; false)
                    echo 'test-success' > $out
                  '';
              }
            ];
          in
          builtins.listToAttrs (
            map
              (t: {
                name = t.name;
                value = pkgs.runCommand t.name { } t.test;
              })
              tests
          );
      }
    );
}
