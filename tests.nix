{ pkgs, wrap, mkWrap }:

pkgs.nixosTest {
  name = "mytest";

  nodes.machine = { config, pkgs, ... }: {
    system.stateVersion = "24.05";
    networking.dhcpcd.enable = false; # boots faster
    environment.systemPackages = [
      wrap
      (mkWrap {
        name = "profile-test";
        package = pkgs.bash;
      })
      (mkWrap {
        name = "profile-test-persistent";
        package = pkgs.bash;
        home = "~/profile-test-home";
      })
      (mkWrap {
        name = "profile-test-cwd";
        package = pkgs.bash;
        shareCwd = true;
        mounts.readOnly = [ "~/profile config" ];
        mounts.writable = [ "~/profile data" ];
      })
      (mkWrap {
        name = "profile-test-environment";
        package = pkgs.bash;
        environment = {
          EXPLICIT = "fixed value $HOME";
          EMPTY = "";
          PASSTHROUGH = null;
          OPTIONAL = null;
        };
      })
    ];

    users.users.alice = {
      isNormalUser = true;
      createHome = true;
    };
  };

  testScript = /* python */ ''
    machine.wait_for_unit("default.target")

    # Run a script as alice
    # This function wraps a bash script with su in order to run as alice.
    # Single quotes are escaped in the script, and the script is handed to su
    # in $'...' ansi quoting in order to allow escaped single quotes inside the
    # single quoted string. The script is run in 'bash strict mode'.
    def as_alice(script):
      script = script.replace("'", r"\'")
      script = "set -euo pipefail\n" + script
      return ( "su "
        "--login alice "
        "--shell ${pkgs.bash}/bin/bash "
        f"--command $'{script}'"
      )

    # as_alice = lambda script: (
    #   f"su --login alice --shell ${pkgs.bash}/bin/bash --command $'{script.replace("'", r"\'")}'"
    # )

    with subtest("Environment variable $HOME is always exposed"):
      machine.succeed(as_alice("""
        # ensure $HOME is set
        echo $HOME | grep '^/home/alice$' ||
          (echo 'Unexpected: $HOME is not set outside sandbox'; false)

        # ensure $HOME remains set in sandbox
        wrap bash -c 'echo $HOME' | grep '^/home/alice$' || 
          (echo 'Unexpected: $HOME is unset in sandbox'; false)
      """))

    with subtest("Environment variable $EDITOR is always exposed"):
      machine.succeed(as_alice("""
        # ensure $EDITOR is set
        export EDITOR=vim
        echo $EDITOR | grep '^vim$' ||
          (echo 'Unexpected: $VIM is not set outside sandbox'; false)

        # ensure $EDITOR remains set in sandbox
        wrap bash -c 'echo $EDITOR' | grep '^vim$' ||
          (echo 'Unexpected: $EDITOR is unset in sandbox: '; false)
      """))

    with subtest("Username is hidden in sandbox, whoami does not work"):
      machine.succeed(as_alice("""
        # ensure `whoami` works outside sandbox
        whoami | grep 'alice' ||
          (echo 'Unexpected: whoami does not work outside sandbox'; false)

        # ensure `whoami` does not work in sandbox
        ! wrap whoami ||
          (echo 'Unexpected: whoami works in sandbox'; false)

        ! wrap whoami 2>&1 | grep "cannot find name for user ID" ||
          (echo 'Unexpected: whoami seems to work in sandbox'; false)
      """))

    with subtest("-u exposes username in sandbox, whoami does work"):
      machine.succeed(as_alice("""
        # ensure `whoami` works outside sandbox
        whoami | grep 'alice' ||
          (echo 'Unexpected: whoami does not work outside sandbox'; false)

        # ensure `whoami` does work in sandbox
        wrap -u whoami ||
          (echo 'Unexpected: whoami does not work in sandbox'; false)

        # ensure `whoami` returns username in sandbox
        wrap -u whoami | grep "^alice$" ||
          (echo 'Unexpected: whoami does not return username in sandbox'; false)
      """))


    with subtest("Environment variable $WAYLAND_DISPLAY is hidden by default"):
      machine.succeed(as_alice("""
        # ensure $WAYLAND_DISPLAY is set outside sandbox
        export WAYLAND_DISPLAY=wl-0
        echo $WAYLAND_DISPLAY | grep '^wl-0$' ||
          (echo 'Unexpected: WAYLAND_DISPLAY is not set outside sandbox'; false)

        # ensure $WAYLAND_DISPLAY is unset in sandbox
        ! (wrap bash -c 'echo $WAYLAND_DISPLAY' | grep '^wl-0$') ||
          (echo 'Unexpected: WAYLAND_DISPLAY is set in sandbox'; false)
      """))

    with subtest("-d exposes $WAYLAND_DISPLAY in sandbox"):
      machine.succeed(as_alice("""
        # ensure $WAYLAND_DISPLAY is set outside sandbox
        export WAYLAND_DISPLAY=wl-0
        echo $WAYLAND_DISPLAY | grep '^wl-0$' ||
          (echo 'Unexpected: WAYLAND_DISPLAY is not set outside sandbox'; false)

        # ensure $WAYLAND_DISPLAY is set in sandbox
        wrap -d bash -c 'echo $WAYLAND_DISPLAY' | grep '^wl-0$' ||
          (echo 'Unexpected: WAYLAND_DISPLAY is not set in sandbox'; false)
      """))

    with subtest("-d exposes wayland socket in sandbox"):
      machine.succeed(as_alice("""
        # ensure $WAYLAND_DISPLAY is set outside sandbox
        export WAYLAND_DISPLAY=wl-12345
        echo $WAYLAND_DISPLAY | grep '^wl-12345$' ||
          (echo 'Unexpected: WAYLAND_DISPLAY is not set outside sandbox'; false)

        # create wayland socket mock
        export XDG_RUNTIME_DIR=/tmp/wayland
        mkdir -p $XDG_RUNTIME_DIR
        touch $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY
        echo $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY | grep '^/tmp/wayland/wl-12345$' ||
          (echo 'Unexpected: WAYLAND socket mock does not exist outside sandbox'; false)

        # ensure $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY is set in sandbox
        wrap -d bash -c 'echo $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY' | grep '^/tmp/wayland/wl-12345$' ||
          (echo 'Unexpected: $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY is not set in sandbox'; false)

        # ensure wayland socket mock exists in sandbox
        wrap -d bash -c 'ls $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY' | grep '^/tmp/wayland/wl-12345$' ||
          (echo 'Unexpected: wayland socket mock does not exist in sandbox'; false)
      """))

    with subtest("Environment variable $DISPLAY is hidden by default"):
      machine.succeed(as_alice("""
        # ensure $DISPLAY is set outside sandbox
        export DISPLAY=:0
        echo $DISPLAY | grep '^:0$' ||
          (echo 'Unexpected: $DISPLAY is not set outside sandbox'; false)

        # ensure $DISPLAY is unset in sandbox
        ! (wrap bash -c 'echo $DISPLAY' | grep '^:0$') ||
          (echo 'Unexpected: $DISPLAY is set in sandbox'; false)
      """))

    with subtest("-d exposes $DISPLAY in sandbox"):
      machine.succeed(as_alice("""
        # ensure $DISPLAY is set outside sandbox
        export DISPLAY=:0
        echo $DISPLAY | grep '^:0$' ||
          (echo 'Unexpected: $DISPLAY is not set outside sandbox'; false)

        # ensure $DISPLAY is set in sandbox
        wrap -d bash -c 'echo $DISPLAY' | grep '^:0$' ||
          (echo 'Unexpected: $DISPLAY is not set in sandbox'; false)
      """))

    with subtest("-d exposes X11 socket in sandbox"):
      machine.succeed(as_alice("""
        mkdir -p /tmp/.X11-unix
        touch /tmp/.X11-unix/X12345

        # ensure $DISPLAY is set outside sandbox
        export DISPLAY=:12345
        echo $DISPLAY | grep '^:12345$' ||
          (echo 'Unexpected: $DISPLAY is not set outside sandbox'; false)

        # ensure $DISPLAY socket is visible in sandbox
        wrap -d bash -c 'ls /tmp/.X11-unix/X12345' | grep 'X12345' ||
          (echo 'Unexpected: $DISPLAY socket is not visible in sandbox'; false)
      """))

    with subtest("-d exposes .Xauthority in sandbox"):
      machine.succeed(as_alice("""
        # create mock home
        export HOME=/tmp/home
        mkdir -p $HOME

        # create mock Xauthority file
        touch $HOME/.Xauthority

        # ensure Xauthority file exists in sandbox
        wrap -d bash -c 'ls $HOME/.Xauthority' | grep '.Xauthority$' ||
          (echo 'Unexpected: .Xauthority is not visible in sandbox'; false)
      """))

    with subtest("-d exposes custom Xauthority file in sandbox"):
      machine.succeed(as_alice("""
        # create mock home
        export HOME=/tmp/home
        mkdir -p $HOME

        # create mock custom Xauthority file
        touch $HOME/myxauthfile
        echo "mysecret" > $HOME/myxauthfile
        export XAUTHORITY=myxauthfile

        # ensure custom Xauthority file exists in sandbox
        wrap -d bash -c 'cat $HOME/.Xauthority' | grep '^mysecret$' ||
          (echo 'Unexpected: custom .Xauthority is not visible in sandbox'; false)
      """))

    with subtest("-d exposes custom absolute path Xauthority file in sandbox"):
      machine.succeed(as_alice("""
        # create mock home
        export HOME=/tmp/home
        mkdir -p $HOME

        # create mock custom Xauthority file
        touch $HOME/myxauthfile
        echo "mysecret" > $HOME/myxauthfile
        export XAUTHORITY=$HOME/myxauthfile

        # ensure custom Xauthority file exists in sandbox
        wrap -d bash -c 'cat $HOME/.Xauthority' | grep '^mysecret$' ||
          (echo 'Unexpected: custom .Xauthority is not visible in sandbox'; false)
      """))

    with subtest("-d uses host authentication regardless of -H order"):
      machine.succeed(as_alice("""
        export HOME=/tmp/desktop-host XAUTHORITY=auth
        sandbox_home="/tmp/desktop home"
        mkdir -p "$HOME" "$sandbox_home"
        echo host-auth > "$HOME/auth"
        echo sandbox-auth > "$sandbox_home/.Xauthority"

        wrap -p -H "$sandbox_home" -d bash -ec '
          test "$(cat "$HOME/.Xauthority")" = host-auth
          ! (echo overwritten > "$HOME/.Xauthority")
        '
        wrap -p -d -H /tmp/other-home -H "$sandbox_home" bash -ec '
          test "$(cat "$HOME/.Xauthority")" = host-auth
        '
        test "$(cat "$HOME/auth")" = host-auth
        test "$(cat "$sandbox_home/.Xauthority")" = sandbox-auth
      """))

    with subtest("-r exposes path readonly"):
      machine.succeed(as_alice("""
        # create some test file
        mkdir -p /tmp/some-dir
        echo "file-content" > /tmp/some-dir/test-file

        # try to read the test file
        wrap -r /tmp/some-dir bash -c 'cat /tmp/some-dir/test-file' | grep '^file-content$' ||
          (echo 'Unexpected: Did not get expected output when trying to read from readonly path'; false)

        # try to write to the test file
        wrap -r /tmp/some-dir bash -c 'echo "Hello World" > /tmp/some-dir/test-file' 2> error || true
        cat error | grep '/tmp/some-dir/test-file: Read-only file system$' ||
          (echo 'Unexpected: Did not get expected error when trying to write to readonly path'; false)
      """))

    with subtest("-w exposes path readwrite"):
      machine.succeed(as_alice("""
        # create some test file
        mkdir -p /tmp/some-dir
        echo "file-content" > /tmp/some-dir/test-file

        # try to read the test file
        wrap -w /tmp/some-dir bash -c 'cat /tmp/some-dir/test-file' | grep '^file-content$' ||
          (echo 'Unexpected: Did not get expected output when trying to read from readwrite path'; false)

        # try to write to the test file
        wrap -w /tmp/some-dir bash -c 'echo "Hello World" > /tmp/some-dir/test-file' ||
          (echo 'Unexpected: Cannot write to readwrite path'; false)

        cat /tmp/some-dir/test-file | grep '^Hello World$' ||
          (echo 'Unexpected: Did not get expected output when reading freshly written file'; false)
      """))

    with subtest("-H keeps HOME mount paths stable and isolates unshared contents"):
      machine.succeed(as_alice("""
        export HOME="/tmp/mount-host[1]"
        mkdir -p "/tmp/mount-host[1]/read config" "/tmp/mount-host[1]/write data" "/tmp/mount-host[1]-other"
        echo host-config > "/tmp/mount-host[1]/read config/value"
        echo host-private > "$HOME/private"
        echo outside-home > "/tmp/mount-host[1]-other/value"
        wrap -p -H "/tmp/mount sandbox" \
          -r "/tmp/mount-host[1]/read config" \
          -w "/tmp/mount-host[1]/write data" \
          -r "/tmp/mount-host[1]-other" bash -ec '
            test "$HOME" = "/tmp/mount-host[1]"
            test "$(cat "$HOME/read config/value")" = host-config
            ! touch "$HOME/read config/forbidden"
            echo sandbox-write > "$HOME/write data/value"
            test "$(cat "/tmp/mount-host[1]-other/value")" = outside-home
            test ! -e "$HOME/private"
          '
        test "$HOME" = "/tmp/mount-host[1]"
        test "$(cat "/tmp/mount-host[1]/write data/value")" = sandbox-write
        test ! -e "/tmp/mount sandbox/write data/value"
        export HOME="/tmp/mount-host[1]/"
        wrap -p -r "/tmp/mount-host[1]/" -H "/tmp/mount sandbox" bash -ec '
          test "$HOME" = "/tmp/mount-host[1]/"
          test "$(cat "$HOME/read config/value")" = host-config
          ! touch "$HOME/forbidden"
        '
        test "$HOME" = "/tmp/mount-host[1]/"
      """))

    with subtest("implicit cwd sharing; -p prevents mounting even with -f"):
      machine.succeed(as_alice("""
        export HOME=/tmp/cwd-home
        mkdir -p "$HOME/project"
        cd "$HOME/project"
        wrap bash -ec 'test "$PWD" = "$HOME/project"; touch cwd-marker'
        test -e cwd-marker
        for flags in -p -pf -fp; do
          wrap "$flags" bash -ec 'test "$PWD" = "$HOME"; test ! -e "$HOME/project/cwd-marker"'
        done
        wrap -H /tmp/cwd-custom-home bash -ec '
          test "$HOME" = /tmp/cwd-home
          test "$PWD" = /tmp/cwd-home/project
        '
      """))

    with subtest("cwd is preserved through explicit mounts and falls back when absent"):
      machine.succeed(as_alice("""
        export HOME=/tmp/preserve-cwd-home
        project="/tmp/preserve-cwd-project with spaces"
        mkdir -p "$HOME" "$project/subdir"
        echo project-data > "$project/subdir/marker"
        cd "$project/subdir"
        wrap -p -r "$project" bash -ec '
          test "$PWD" = "/tmp/preserve-cwd-project with spaces/subdir"
          test "$(cat marker)" = project-data
          ! touch forbidden
        '
        wrap -p -w "$project" bash -ec '
          test "$PWD" = "/tmp/preserve-cwd-project with spaces/subdir"
          touch writable-marker
        '
        test -e writable-marker
        wrap -p -H /tmp/preserve-cwd-fallback bash -ec '
          test "$PWD" = "$HOME"
          test "$HOME" = /tmp/preserve-cwd-home
        '
        cd /
        wrap -p bash -ec 'test "$PWD" = /'
        cd "$HOME"
        wrap -p -H "$HOME" bash -ec 'test "$PWD" = "$HOME"'
      """))

    with subtest("persistent home keeps host-visible project cwd across launches"):
      machine.succeed(as_alice("""
        export HOME=/tmp/stable-home
        storage="$HOME/jail"
        mkdir -p "$storage" "$HOME/src/nixos"
        echo host-private > "$HOME/private"
        echo project-data > "$HOME/src/nixos/marker"
        ln -s "$HOME" /tmp/stable-home-alias
        cd /tmp/stable-home-alias
        wrap -p -H "$storage" -w "$HOME/src" bash -ec '
          test "$HOME" = /tmp/stable-home
          test "$PWD" = "$HOME"
          test ! -e "$HOME/private"
          touch "$HOME/persistent-marker"
          cd "$HOME/src/nixos"
          printf "%s" "$PWD" > "$HOME/reported-cwd"
        '
        test -e "$storage/persistent-marker"
        test ! -e "$HOME/persistent-marker"
        cd "$(cat "$storage/reported-cwd")"
        wrap -p -H "$storage" -w "$HOME/src" bash -ec '
          test "$PWD" = "$HOME/src/nixos"
          test "$(cat marker)" = project-data
          test -e "$HOME/persistent-marker"
          touch project-write
        '
        test -e project-write
        cd "$HOME"
        wrap -f -H "$storage" bash -ec 'test -e private'
      """))

    with subtest("home and protected-path aliases are not shared without -f"):
      machine.succeed(as_alice("""
        export HOME="/tmp/protected-home[1]/"
        mkdir -p "$HOME"
        touch "$HOME/host-marker"
        cd "$HOME"
        wrap bash -ec 'test ! -e "$HOME/host-marker"'
        wrap -f bash -ec 'test -e "$HOME/host-marker"'
        wrap -H /tmp/another-home bash -ec 'test . -ef "$HOME"; test ! -e "$HOME/host-marker"'
        ln -s "$HOME" /tmp/home-alias
        cd /tmp/home-alias
        wrap bash -ec 'test ! -e "$HOME/host-marker"'
        ln -s /etc /tmp/etc-alias
        cd /tmp/etc-alias
        wrap bash -ec 'test "$PWD" = /etc; test ! -e /etc/passwd'
      """))

    with subtest("forced root sharing and symlinked read-only profiles work"):
      machine.succeed(as_alice("""
        cd /
        wrap -f bash -ec 'test "$PWD" = /'
        mkdir -p /tmp/profile-project /tmp/profile-target
        echo profile-data > /tmp/profile-target/marker
        cd /tmp/profile-project
        ln -s /tmp/profile-target profile-link
        NIX_PROFILES="$NIX_PROFILES $PWD/profile-link" wrap bash -ec '
          test "$(cat profile-link/marker)" = profile-data
          ! touch profile-link/write-marker
        '
        test ! -e /tmp/profile-target/write-marker
      """))

    with subtest("Network files are available only with -n"):
      machine.succeed(as_alice("""
        # Without -n, resolv.conf should not be visible
        ! wrap bash -c 'ls /etc/resolv.conf' ||
          (echo 'Unexpected: /etc/resolv.conf visible without -n'; false)

        # With -n, resolv.conf and /etc/ssl should be visible
        wrap -n bash -c 'ls /etc/resolv.conf' | grep '^/etc/resolv.conf$' ||
          (echo 'Unexpected: /etc/resolv.conf not visible with -n'; false)
        wrap -n bash -c 'test -d /etc/ssl && echo ok' | grep '^ok$' ||
          (echo 'Unexpected: /etc/ssl not visible with -n'; false)
      """))

    with subtest("Audio sockets visible only with -a"):
      machine.succeed(as_alice("""
        export XDG_RUNTIME_DIR=/tmp/xdg
        mkdir -p "$XDG_RUNTIME_DIR/pulse"
        touch "$XDG_RUNTIME_DIR/pulse/native"
        touch "$XDG_RUNTIME_DIR/pipewire-0"
        touch "$XDG_RUNTIME_DIR/pipewire-0.lock"

        # Without -a, these paths should not be visible in sandbox
        ! (wrap bash -c 'ls $XDG_RUNTIME_DIR/pulse/native') ||
          (echo 'Unexpected: pulse/native visible without -a'; false)
        ! (wrap bash -c 'ls $XDG_RUNTIME_DIR/pipewire-0') ||
          (echo 'Unexpected: pipewire-0 visible without -a'; false)
        ! (wrap bash -c 'ls $XDG_RUNTIME_DIR/pipewire-0.lock') ||
          (echo 'Unexpected: pipewire-0.lock visible without -a'; false)

        # With -a, they should be visible
        wrap -a bash -c 'ls $XDG_RUNTIME_DIR/pulse/native' | grep 'pulse/native' ||
          (echo 'Unexpected: pulse/native not visible with -a'; false)
        wrap -a bash -c 'ls $XDG_RUNTIME_DIR/pipewire-0' | grep 'pipewire-0$' ||
          (echo 'Unexpected: pipewire-0 not visible with -a'; false)
        wrap -a bash -c 'ls $XDG_RUNTIME_DIR/pipewire-0.lock' | grep 'pipewire-0.lock$' ||
          (echo 'Unexpected: pipewire-0.lock not visible with -a'; false)
      """))

    with subtest("DBus session socket visible only with -b"):
      machine.succeed(as_alice("""
        # Create a fake DBus session socket and export address
        touch /tmp/dbus-sock
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/dbus-sock"

        # Without -b, it should not be visible
        ! (wrap bash -c 'ls /tmp/dbus-sock') ||
          (echo 'Unexpected: DBus socket visible without -b'; false)

        # With -b, it should be visible
        wrap -b bash -c 'ls /tmp/dbus-sock' | grep '/tmp/dbus-sock' ||
          (echo 'Unexpected: DBus socket not visible with -b'; false)
      """))

    with subtest("Env var passthrough via -e and default stripping"):
      machine.succeed(as_alice("""
        export SECRET_VAR=topsecret

        # By default SECRET_VAR should be stripped
        wrap bash -c 'echo ''${SECRET_VAR:-unset}' | grep '^unset$' ||
          (echo 'Unexpected: SECRET_VAR visible without -e'; false)

        # With -e SECRET_VAR it should be visible
        wrap -e SECRET_VAR bash -c 'echo ''${SECRET_VAR:-unset}' | grep '^topsecret$' ||
          (echo 'Unexpected: SECRET_VAR not visible with -e'; false)
      """))

    with subtest("symlinked NIX_PROFILES work with and without a bound ancestor"):
      machine.succeed("""
        install -d -o alice /nix/var/nix/profiles/nixwrap-regression-target
        ln -s nixwrap-regression-target /nix/var/nix/profiles/nixwrap-regression
      """)
      machine.succeed(as_alice("""
        target=/nix/var/nix/profiles/nixwrap-regression-target
        echo profile-data > "$target/marker"
        ln -s "$target" "$HOME/regression-profile"
        export NIX_PROFILES="$NIX_PROFILES /nix/var/nix/profiles/nixwrap-regression $HOME/regression-profile"

        # -p ensures the shared-cwd workaround cannot hide the regression.
        wrap -p bash -ec '
          test -L /nix/var/nix/profiles/nixwrap-regression
          for profile in /nix/var/nix/profiles/nixwrap-regression "$HOME/regression-profile"; do
            test "$(cat "$profile/marker")" = profile-data
            ! touch "$profile/write-marker"
          done
          /bin/sh -ec "test -d /nix"
        '
        test ! -e "$target/write-marker"
      """))

    with subtest("NIX_PROFILES are ro-bound and not writable"):
      machine.succeed("""
        mkdir -p /profile
      """)
      machine.succeed(as_alice("""
        export NIX_PROFILES="''${NIX_PROFILES} /profile"

        # Directory should be visible in sandbox
        wrap bash -c 'ls -l /profile' | grep '^total 0$' ||
          (echo 'Unexpected: NIX_PROFILES dir not visible in sandbox'; false)

        # Writing inside should fail due to ro-bind
        wrap bash -c 'echo hi > /profile/file' 2> error || true
        cat error | grep '/profile/file: Read-only file system$' ||
          (echo 'Unexpected: /profile is writable in sandbox'; false)
      """))

    with subtest("HOME is created and writable inside sandbox"):
      machine.succeed(as_alice("""
        export HOME=/tmp/new-home-absent
        rm -rf "$HOME"

        # With -p (no cwd sharing), bwrap --dir should create HOME inside sandbox and be writable
        wrap -p bash -c 'test -d "$HOME" -a -w "$HOME" && echo ok' | grep '^ok$' ||
          (echo 'Unexpected: $HOME not created or not writable inside sandbox'; false)
      """))

    with subtest("r/w shared directory is created if it does not exist"):
      machine.succeed(as_alice("""
        export SOME_DIR=/tmp/some-dir
        rm -rf "$SOME_DIR"

        wrap -p -e SOME_DIR -r "$SOME_DIR" bash -c 'test -d "$SOME_DIR" && echo ok' | grep '^ok$' ||
          (echo 'Unexpected: -r $SOME_DIR does not create directory'; false)
        wrap -p -e SOME_DIR -w "$SOME_DIR" bash -c 'test -d "$SOME_DIR" && echo ok' | grep '^ok$' ||
          (echo 'Unexpected: -w $SOME_DIR does not create directory'; false)
      """))

    with subtest("-- forwards BWRAP_ARGS to bwrap"):
      machine.succeed(as_alice("""
        mkdir -p /tmp/bwrap-args-test
        echo "bwrap-args-content" > /tmp/bwrap-args-test/data

        # BWRAP_ARGS after -- should be honoured as bwrap options
        wrap -- --ro-bind /tmp/bwrap-args-test /tmp/bwrap-args-test bash -c 'cat /tmp/bwrap-args-test/data' | grep '^bwrap-args-content$' ||
          (echo 'Unexpected: BWRAP_ARGS not forwarded to bwrap'; false)

        # Bare -- separator should be consumed and not break the command
        wrap -- bash -c 'echo hi' | grep '^hi$' ||
          (echo 'Unexpected: -- separator not handled'; false)

        # Wrap options combined with -- and BWRAP_ARGS
        wrap -p -- --ro-bind /tmp/bwrap-args-test /tmp/bwrap-args-test bash -c 'cat /tmp/bwrap-args-test/data' | grep '^bwrap-args-content$' ||
          (echo 'Unexpected: -p with BWRAP_ARGS failed'; false)
      """))

    with subtest("-p -H preserves available cwd and persists home data"):
      machine.succeed(as_alice("""
        cd /tmp
        wrap -p -H "nixwrap home" bash -ec '
          test "$HOME" = /home/alice
          test "$PWD" = /tmp
          touch "$HOME/file"
        '
        test -e "/tmp/nixwrap home/file"
      """))

    with subtest("mkWrap leaves the default home isolated without persisting writes"):
      machine.succeed(as_alice("""
        echo host-only > "$HOME/profile-host-marker"
        profile-test -c 'test "$HOME" = /home/alice && test "$PWD" = "$HOME" && test ! -e "$HOME/profile-host-marker" && touch "$HOME/profile-sandbox-marker"'
        test ! -e "$HOME/profile-sandbox-marker"
      """))

    with subtest("mkWrap sets explicit values and passes through runtime environment"):
      machine.succeed(as_alice("""
        export EXPLICIT=ignored EMPTY=ignored PASSTHROUGH="caller value" SECRET_VAR=hidden
        unset OPTIONAL
        profile-test-environment -euc '
          test "$EXPLICIT" = "fixed value \\$HOME"
          test "''${EMPTY+x}" = x && test "$EMPTY" = ""
          test "$PASSTHROUGH" = "caller value"
          test "''${OPTIONAL+x}" = ""
          test "''${SECRET_VAR+x}" = ""
        '
        export PASSTHROUGH="changed value" OPTIONAL=""
        profile-test-environment -euc '
          test "$PASSTHROUGH" = "changed value"
          test "''${OPTIONAL+x}" = x && test "$OPTIONAL" = ""
        '
      """))

    with subtest("mkWrap persists home data without changing HOME"):
      machine.succeed(as_alice("""
        profile-test-persistent -c 'test "$HOME" = /home/alice && touch "$HOME/profile-marker"'
        test -e /home/alice/profile-test-home/profile-marker
      """))

    with subtest("mkWrap resolves ~/ at launch and shares cwd when enabled"):
      machine.succeed(as_alice("""
        export HOME="/tmp/runtime home"
        mkdir -p "$HOME/project" "$HOME/profile config"
        echo config-data > "$HOME/profile config/marker"
        cd "$HOME/project"
        profile-test-cwd -ec '
          test "$PWD" = "$HOME/project"
          test "$(cat "$HOME/profile config/marker")" = config-data
          ! touch "$HOME/profile config/new-file"
          touch cwd-marker "$HOME/profile data/marker"
        '
        test -e cwd-marker
        test -e "$HOME/profile data/marker"
      """))
  '';
}

