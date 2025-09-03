{ pkgs, wrap }:

pkgs.nixosTest {
  name = "mytest";

  nodes.machine = { config, pkgs, ... }: {
    system.stateVersion = "24.05";
    networking.dhcpcd.enable = false; # boots faster
    environment.systemPackages = [ wrap ];

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

    with subtest("cwd is exposed by default"):
      machine.succeed(as_alice("""
        mkdir -p /tmp/some-dir
        cd /tmp/some-dir
        echo "file-content" > test-file

        # Expect cat to succeed inside sandbox
        wrap bash -c 'cat test-file' | grep '^file-content$' ||
          (echo 'Unexpected: cwd not exposed by default'; false)
      """))

    with subtest("-p does not expose cwd"):
      machine.succeed(as_alice("""
        mkdir -p /tmp/some-dir
        cd /tmp/some-dir
        echo "file-content" > test-file

        # Expect cat to fail inside sandbox when -p is used
        wrap -p bash -c 'cat test-file; echo $?' | grep '^1$' ||
          (echo 'Unexpected: cwd exposed when using -p'; false)
      """))

    with subtest("-p cds to root"):
      machine.succeed(as_alice("""
        mkdir -p /tmp/new-home
        export HOME=/tmp/new-home

        # Expect pwd to return / in sandbox
        wrap -p bash -c 'pwd' | grep '^/$' ||
          (echo 'Unexpected: -p did not change cwd as expected'; false)
      """))

    with subtest("$HOME as cwd is not shared implicitly"):
      machine.succeed(as_alice("""
        # setup prerequisites
        mkdir -p /tmp/new-home
        export HOME=/tmp/new-home
        touch /tmp/new-home/something-in-home
        cd $HOME

        # expect cwd to be changed to /
        wrap bash -c 'pwd' | grep '^/$' ||
          (echo 'Unexpected: Cwd in sandbox is not /'; false)

        # expect $HOME to be empty
        wrap bash -c 'ls -l $HOME' | grep '^total 0$' ||
          (echo 'Unexpected: Sandbox $HOME is not empty'; false)
      """))

    with subtest("/etc as cwd is excluded from implicit sharing"):
      machine.succeed(as_alice("""
        cd /etc
        wrap bash -c 'pwd' | grep '^/$' ||
          (echo 'Unexpected: /etc shared implicitly as cwd'; false)
      """))

    with subtest("-f forces sharing HOME as cwd"):
      machine.succeed(as_alice("""
        # setup prerequisites
        mkdir -p /tmp/new-home
        export HOME=/tmp/new-home
        touch /tmp/new-home/something-in-home
        cd $HOME

        # expect cwd to be $HOME
        wrap -f bash -c 'pwd' | grep '^/tmp/new-home$' ||
          (echo 'Unexpected: Cwd in sandbox is not $HOME'; false)

        # expect file in $HOME
        wrap -f bash -c 'ls $HOME' | grep '^something-in-home$' ||
          (echo 'Unexpected: Sandbox $HOME is empty'; false)
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
  '';
}

