{
  pkgs,
  wrap,
  mkWrap,
}:

let
  # A file-valued root referencing another file exercises transitive closure sharing.
  closureDependency = pkgs.writeText "closure-dependency" "closure-data";
  closureRoot = pkgs.writeText "closure-root" "${closureDependency}";
  unsharedPath = pkgs.writeText "unshared-store-path" "private-data";
  # Same command name, different results: -s order must determine command lookup.
  firstCommand = pkgs.writeShellScriptBin "closure-command" "printf first";
  secondCommand = pkgs.writeShellScriptBin "closure-command" "printf second";
  # A persistent client keeps the user manager subscribed to broadcast signals.
  dbusPython = pkgs.python3.withPackages (ps: [ ps.dbus-python ]);
  dbusCaller = mkWrap {
    name = "profile-test-dbus";
    package = pkgs.bash;
    executable = "bash";
    dbus.call = [ "org.freedesktop.systemd1=org.freedesktop.DBus.Properties.Get@/org/freedesktop/systemd1/unit/dbus_2eservice" ];
  };
  hostDbusCaller = mkWrap {
    name = "profile-test-host-dbus";
    package = pkgs.bash;
    executable = "bash";
    capabilities.hostDbus = true;
  };
in
pkgs.testers.nixosTest {
  name = "mytest";

  nodes.machine = { config, pkgs, ... }: {
    system.stateVersion = "24.05";
    # CLI-only fixtures must be registered in the guest store for nix-store queries.
    virtualisation.additionalPaths = [ firstCommand secondCommand ];
    networking.dhcpcd.enable = false; # boots faster
    networking.defaultGateway = "192.168.1.3";
    networking.nameservers = [ "192.168.1.3" ];
    # WireGuard's encrypted transport between machine and peer.
    networking.firewall.allowedUDPPorts = [ 51820 ];
    # Match common NixOS: disable legacy TIOCSTI (nixpkgs common-config.nix)
    boot.kernel.sysctl = {
      "dev.tty.legacy_tiocsti" = 0;
    };
    environment.systemPackages = [
      wrap
      dbusCaller
      hostDbusCaller
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.dbus
      pkgs.systemd
      pkgs.socat
      pkgs.curl
      pkgs.dig
      pkgs.wireguard-tools
      (mkWrap {
        name = "profile-test";
        package = pkgs.bash;
        executable = "bash";
      })
      (mkWrap {
        name = "profile-test-closures";
        package = pkgs.bash;
        executable = "bash";
        closures = [ closureRoot ];
      })
      (mkWrap {
        name = "profile-test-host-ports";
        package = pkgs.bash;
        executable = "bash";
        capabilities.network = true;
        hostPorts = [ 18080 ];
      })
      (mkWrap {
        name = "profile-test-persistent";
        package = pkgs.bash;
        executable = "bash";
        home = "~/profile-test-home";
      })
      (mkWrap {
        name = "profile-test-cwd";
        package = pkgs.bash;
        executable = "bash";
        shareCwd = true;
        mounts.readOnly = [ "~/profile config" ];
        mounts.writable = [ "~/profile data" ];
      })
      (mkWrap {
        name = "profile-test-environment";
        package = pkgs.bash;
        executable = "bash";
        environment = {
          EXPLICIT = "fixed value $HOME";
          EMPTY = "";
          PASSTHROUGH = null;
          OPTIONAL = null;
        };
      })
    ];

    # Host echo services are positive controls for the sandbox isolation checks.
    # TCP 18080: explicitly allowed by profile-test-host-ports.
    # TCP 18083: left blocked unless a second -P is supplied.
    # UDP 18081 and the abstract socket must not be exposed by TCP forwarding.
    systemd.services.network-test-host-sockets.script = ''
      ${pkgs.socat}/bin/socat ABSTRACT-LISTEN:wrap-host-abstract,fork EXEC:${pkgs.coreutils}/bin/cat &
      ${pkgs.socat}/bin/socat TCP4-LISTEN:18080,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/cat &
      ${pkgs.socat}/bin/socat TCP6-LISTEN:18080,bind=::1,ipv6only=1,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/cat &
      ${pkgs.socat}/bin/socat TCP4-LISTEN:18083,bind=127.0.0.1,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/cat &
      # Keep accepting UDP clients with different source ports between probes.
      ${pkgs.nmap}/bin/ncat -u -l -k 127.0.0.1 18081 --exec ${pkgs.coreutils}/bin/cat &
      wait
    '';

    services.dbus.enable = true;
    services.dbus.implementation = "dbus";

    # A stock echo process supplies the unrelated name used by filtering tests.
    systemd.user.services.nixwrap-hidden.serviceConfig = {
      Type = "dbus";
      BusName = "org.example.Hidden";
      ExecStart = "${pkgs.dbus}/bin/dbus-test-tool echo --name=org.example.Hidden";
    };

    users.users.alice = {
      isNormalUser = true;
      createHome = true;
      linger = true;
    };
  };

  nodes.peer = { pkgs, ... }: {
    system.stateVersion = "24.05";
    networking.dhcpcd.enable = false;
    environment.systemPackages = [ pkgs.wireguard-tools ];
    networking.interfaces.eth1.ipv4.addresses = [
      {
        address = "192.168.1.3";
        prefixLength = 24;
      }
    ];
    networking.firewall.allowedTCPPorts = [ 8080 ];
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        address = [
          "/network.test/192.168.1.3"
          "/wg.test/10.77.0.2"
          "/wg.test/fd77::2"
        ];
        # wg1 is created at runtime; DNS must also answer over the tunnel.
        interface = [ "eth1" "wg1" ];
      };
    };
    # DNS, WireGuard transport, and the IPv4/IPv6 UDP echo probes below.
    networking.firewall.allowedUDPPorts = [ 53 51820 18082 ];
    # Echo payloads on both address families to exercise UDP independently of TCP.
    systemd.services.network-test-udp = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.socat}/bin/socat UDP4-RECVFROM:18082,fork EXEC:${pkgs.coreutils}/bin/cat";
    };
    systemd.services.network-test-udp6 = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.socat}/bin/socat UDP6-RECVFROM:18082,ipv6only=1,fork EXEC:${pkgs.coreutils}/bin/cat";
    };
    services.nginx = {
      enable = true;
      virtualHosts."network.test" = {
        listen = [
          { addr = "0.0.0.0"; port = 8080; }
          { addr = "[::]"; port = 8080; }
        ];
        root = pkgs.writeTextDir "index.html" "outbound-network-ok";
        # The observed client address distinguishes LAN egress from tunnel egress.
        locations."/source".extraConfig = ''return 200 "$remote_addr";'';
      };
    };
  };

  nodes.machine_tiocsti = { config, pkgs, ... }: {
    system.stateVersion = "24.05";
    networking.dhcpcd.enable = false; # boots faster
    # Enable legacy TIOCSTI to test the error path
    boot.kernel.sysctl = {
      "dev.tty.legacy_tiocsti" = 1;
    };
    environment.systemPackages = [ wrap ];

    users.users.alice = {
      isNormalUser = true;
      createHome = true;
    };
  };

  testScript = /* python */ ''
    machine.wait_for_unit("default.target")
    machine_tiocsti.wait_for_unit("default.target")

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


    from shlex import quote
    from textwrap import dedent

    # Use Alice's real user bus. The unrelated echo service is stateless and
    # stays running; only clients and names created by a subtest need cleanup.
    alice_uid = machine.succeed("id -u alice").strip()
    machine.wait_for_unit(f"user@{alice_uid}.service")
    machine.succeed(as_alice(
      "XDG_RUNTIME_DIR=/run/user/$(id -u) "
      "systemctl --user start dbus.service nixwrap-hidden.service"
    ))

    def as_dbus_user(script):
      """Set the host session environment and clean up this subtest's resources."""
      return as_alice(dedent("""
        export XDG_RUNTIME_DIR=/run/user/$(id -u)
        export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus

        work=$(mktemp -d)
        cleanup() {
          for pid in $(jobs -pr); do kill "$pid" 2>/dev/null || true; done
          wait 2>/dev/null || true
          rm -rf "$work"
        }
        trap cleanup EXIT
      """) + dedent(script))

    # Scripts stay local to each case. quote() passes them as command arguments,
    # leaving stdin free. Python joins backslash-continued shell command lines
    # before as_alice hands the script through its outer shell quoting.

    with subtest("Without D-Bus options applications cannot use the host session bus"):
      sandbox_script = dedent("""
        set -euo pipefail

        [[ ! -v DBUS_SESSION_BUS_ADDRESS ]]
        if busctl --address="unix:path=/run/user/$(id -u)/bus" --timeout=3 call \
            org.example.Hidden /org/example/Hidden org.example.Hidden Ping; then
          echo "Host session bus accessible without permission" >&2
          exit 1
        fi
      """)

      machine.succeed(as_dbus_user("""
        # The host call works. The sandbox must also block a client that knows
        # the socket path and does not need DBUS_SESSION_BUS_ADDRESS.
        busctl --user call \
          org.example.Hidden /org/example/Hidden org.example.Hidden Ping

      """ + "wrap -p bash -c " + quote(sandbox_script)))

    with subtest("-B and capabilities.hostDbus access the host session bus directly"):
      # Preserve the real address, and call two unrelated services.
      sandbox_script = dedent("""
        set -euo pipefail
        [[ $DBUS_SESSION_BUS_ADDRESS == unix:path=/run/user/$(id -u)/bus ]]

        busctl --user --timeout=3 call \
          org.example.Hidden /org/example/Hidden org.example.Hidden Ping

        unit=$(busctl --user call \
          org.freedesktop.systemd1 /org/freedesktop/systemd1 \
          org.freedesktop.systemd1.Manager GetUnit s dbus.service)
        [[ $unit == 'o "/org/freedesktop/systemd1/unit/dbus_2eservice"' ]]
      """)

      for launcher in [
        "wrap -p -B bash",
        "${hostDbusCaller}/bin/profile-test-host-dbus",
      ]:
        machine.succeed(as_dbus_user(launcher + " -c " + quote(sandbox_script)))

    with subtest("-b see discovers a service without allowing calls or ownership"):
      sandbox_script = dedent("""
        set -euo pipefail

        owner=$(busctl --user call \
          org.freedesktop.DBus /org/freedesktop/DBus \
          org.freedesktop.DBus NameHasOwner s org.freedesktop.systemd1)
        [[ $owner == 'b true' ]]

        names=$(busctl --user call \
          org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ListNames)
        [[ $names == *org.freedesktop.systemd1* && $names != *org.example.Hidden* ]]

        # Discovery is not permission to call the service or register a name.
        if output=$(busctl --user call \
            org.freedesktop.systemd1 /org/freedesktop/systemd1 \
            org.freedesktop.systemd1.Manager GetUnit s dbus.service 2>&1); then
          exit 1
        fi
        [[ $output == *"Access denied"* ]]

        if output=$(busctl --user call \
            org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus RequestName su org.example.Unallowed 4 2>&1); then
          exit 1
        fi
        [[ $output == *ServiceUnknown* ]]
      """)

      machine.succeed(as_dbus_user("""
        # The method works on the host, so sandbox denial is a policy decision.
        busctl --user call \
          org.freedesktop.systemd1 /org/freedesktop/systemd1 \
          org.freedesktop.systemd1.Manager GetUnit s dbus.service

      """ + "wrap -p -b see:org.freedesktop.systemd1 bash -c " + quote(sandbox_script)))

    with subtest("-b call and dbus.call restrict method, interface, path and service"):
      machine.succeed(as_dbus_user("""
        # Every forbidden operation below is valid outside the sandbox.
        busctl --user call org.freedesktop.systemd1 \
          /org/freedesktop/systemd1/unit/dbus_2eservice \
          org.freedesktop.DBus.Properties GetAll s org.freedesktop.systemd1.Unit
        busctl --user call org.freedesktop.systemd1 \
          /org/freedesktop/systemd1/unit/dbus_2eservice org.freedesktop.DBus.Peer Ping
        busctl --user call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
          org.freedesktop.DBus.Properties Get ss org.freedesktop.systemd1.Manager Version
        busctl --user call \
          org.example.Hidden /org/example/Hidden org.example.Hidden Ping
      """))

      # Share behavior checks, not fixtures or assertions hidden in a helper.
      sandbox_script = dedent("""
        set -euo pipefail

        denied() {
          local output
          if output=$("$@" 2>&1); then
            echo "Unexpectedly allowed: $*" >&2
            return 1
          fi
          case "$output" in
            *AccessDenied*|*ServiceUnknown*|*NameHasNoOwner*|*"Access denied"*) ;;
            *) echo "$output" >&2; return 1 ;;
          esac
        }

        id=$(busctl --user --timeout=3 call org.freedesktop.systemd1 \
          /org/freedesktop/systemd1/unit/dbus_2eservice \
          org.freedesktop.DBus.Properties Get ss org.freedesktop.systemd1.Unit Id)
        [[ $id == 'v s "dbus.service"' ]]

        # Change one part of the allowed call at a time.
        denied busctl --user call org.freedesktop.systemd1 \
          /org/freedesktop/systemd1/unit/dbus_2eservice \
          org.freedesktop.DBus.Properties GetAll s org.freedesktop.systemd1.Unit
        denied busctl --user call org.freedesktop.systemd1 \
          /org/freedesktop/systemd1/unit/dbus_2eservice org.freedesktop.DBus.Peer Ping
        denied busctl --user call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
          org.freedesktop.DBus.Properties Get ss org.freedesktop.systemd1.Manager Version
        denied busctl --user call \
          org.example.Hidden /org/example/Hidden org.example.Hidden Ping
      """)

      for launcher in [
        "wrap -p -b 'call:org.freedesktop.systemd1=org.freedesktop.DBus.Properties.Get@/org/freedesktop/systemd1/unit/dbus_2eservice' bash",
        "${dbusCaller}/bin/profile-test-dbus",
      ]:
        machine.succeed(as_dbus_user(launcher + " -c " + quote(sandbox_script)))

    with subtest("Repeated -b rules add permissions rather than replacing earlier rules"):
      # Both methods must work in the same sandbox.
      sandbox_script = dedent("""
        set -euo pipefail

        id=$(busctl --user call org.freedesktop.systemd1 \
          /org/freedesktop/systemd1/unit/dbus_2eservice \
          org.freedesktop.DBus.Properties Get ss org.freedesktop.systemd1.Unit Id)
        [[ $id == 'v s "dbus.service"' ]]

        unit=$(busctl --user call \
          org.freedesktop.systemd1 /org/freedesktop/systemd1 \
          org.freedesktop.systemd1.Manager GetUnit s dbus.service)
        [[ $unit == 'o "/org/freedesktop/systemd1/unit/dbus_2eservice"' ]]
      """)

      machine.succeed(as_dbus_user(
        "wrap -p "
        "-b 'call:org.freedesktop.systemd1=org.freedesktop.DBus.Properties.Get"
        "@/org/freedesktop/systemd1/unit/dbus_2eservice' "
        "-b 'call:org.freedesktop.systemd1=org.freedesktop.systemd1.Manager.GetUnit"
        "@/org/freedesktop/systemd1' bash -c " + quote(sandbox_script)
      ))

    with subtest("-b talk permits reads and writes despite an additional narrow call rule"):
      sandbox_script = dedent("""
        set -euo pipefail

        # Neither operation matches the GetUnit rule: talk remains authoritative.
        id=$(busctl --user call org.freedesktop.systemd1 \
          /org/freedesktop/systemd1/unit/dbus_2eservice \
          org.freedesktop.DBus.Properties Get ss org.freedesktop.systemd1.Unit Id)
        [[ $id == 'v s "dbus.service"' ]]
        busctl --user call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
          org.freedesktop.systemd1.Manager SetEnvironment as 1 NIXWRAP_DBUS_TEST=changed

        # Broad access to the manager still grants no access to another service.
        if output=$(busctl --user call \
            org.example.Hidden /org/example/Hidden org.example.Hidden Ping 2>&1); then
          exit 1
        fi
        [[ $output == *ServiceUnknown* || $output == *NameHasNoOwner* ]]
        names=$(busctl --user call \
          org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ListNames)
        [[ $names != *org.example.Hidden* ]]
      """)

      machine.succeed(as_dbus_user("""
        # Restore the test-specific manager variable even if an assertion fails.
        restore_environment() {
          busctl --user call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
            org.freedesktop.systemd1.Manager UnsetEnvironment as 1 NIXWRAP_DBUS_TEST
          cleanup
        }
        trap restore_environment EXIT
        busctl --user call \
          org.example.Hidden /org/example/Hidden org.example.Hidden Ping

      """ +
        "wrap -p -b talk:org.freedesktop.systemd1 "
        "-b 'call:org.freedesktop.systemd1=org.freedesktop.systemd1.Manager.GetUnit"
        "@/org/freedesktop/systemd1' bash -c " + quote(sandbox_script) + """

        # Verify the write from outside the sandbox, not only its exit status.
        [[ $(systemctl --user show-environment) == *NIXWRAP_DBUS_TEST=changed* ]]
      """))

    with subtest("-b own serves its selected name but cannot acquire other names"):
      service = dedent("""
        set -euo pipefail

        # Ownership grants neither discovery nor ownership of unrelated names.
        owner=$(busctl --user call \
          org.freedesktop.DBus /org/freedesktop/DBus \
          org.freedesktop.DBus NameHasOwner s org.freedesktop.systemd1)
        [[ $owner == 'b false' ]]
        if output=$(busctl --user call \
            org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus RequestName su org.example.Unallowed 4 2>&1); then
          exit 1
        fi
        [[ $output == *ServiceUnknown* ]]

        echo "$DBUS_SESSION_BUS_ADDRESS"
        exec dbus-test-tool echo --name=org.example.Owned
      """)

      machine.succeed(as_dbus_user(
        "wrap -p -b own:org.example.Owned bash -c "
        + quote(service) + """ >"$work/address" &
        service_pid=$!

        for attempt in {1..100}; do
          owner=$(busctl --user call \
            org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus NameHasOwner s org.example.Owned)
          [[ $owner == 'b true' ]] && break
          kill -0 "$service_pid"
          sleep 0.05
        done

        # Host clients can call the application: own is not an inbound ACL.
        busctl --user --timeout=3 call \
          org.example.Owned /org/example/Owned org.example.Owned Ping

        kill "$service_pid"
        wait "$service_pid" || true
        owner=$(busctl --user call \
          org.freedesktop.DBus /org/freedesktop/DBus \
          org.freedesktop.DBus NameHasOwner s org.example.Owned)
        [[ $owner == 'b false' ]]

        # Terminating the application also removes its proxy socket directory.
        address=$(cat "$work/address")
        socket=''${address#unix:path=}
        [[ ! -e ''${socket%/*} ]]
      """))

    with subtest("-b broadcast filters signals independently of call permissions"):
      # systemd emits signals only while a bus client stays subscribed.
      # systemd-run may use the private manager socket, so it is not sufficient.
      subscriber = dedent("""
        import dbus, signal

        bus = dbus.SessionBus()
        bus.get_object(
            "org.freedesktop.systemd1", "/org/freedesktop/systemd1"
        ).Subscribe(dbus_interface="org.freedesktop.systemd1.Manager")
        print("ready", flush=True)
        signal.pause()
      """)

      machine.succeed(as_dbus_user("""
        wait_for_log() {
          for attempt in {1..100}; do
            grep -q "$1" "$2" && return
            sleep 0.05
          done
          cat "$2" >&2
          return 1
        }

        # Observe the same unit creation with each permission. NameAcquired
        # confirms each monitor is connected before we generate the event.
        for mode in allowed member interface path see call talk; do
          case $mode in
            allowed)
              rule='broadcast:org.freedesktop.systemd1=org.freedesktop.systemd1.Manager.UnitNew@/org/freedesktop/systemd1'
              ;;
            member)
              rule='broadcast:org.freedesktop.systemd1=org.freedesktop.systemd1.Manager.UnitFilesChanged@/org/freedesktop/systemd1'
              ;;
            interface)
              rule='broadcast:org.freedesktop.systemd1=org.freedesktop.DBus.Properties.UnitNew@/org/freedesktop/systemd1'
              ;;
            path)
              rule='broadcast:org.freedesktop.systemd1=org.freedesktop.systemd1.Manager.UnitNew@/org/freedesktop/systemd1/unit/dbus_2eservice'
              ;;
            see) rule='see:org.freedesktop.systemd1' ;;
            call) rule='call:org.freedesktop.systemd1=org.freedesktop.systemd1.Manager.*' ;;
            talk) rule='talk:org.freedesktop.systemd1' ;;
          esac

          wrap -p -b "$rule" dbus-monitor --session \
            "type='signal',interface='org.freedesktop.systemd1.Manager',arg0='nixwrap-signal.service'" \
            >"$work/$mode" 2>&1 &
          wait_for_log member=NameAcquired "$work/$mode"
        done

      """ + "${dbusPython}/bin/python3 -c " + quote(subscriber) + """ >"$work/subscribed" &
        wait_for_log ready "$work/subscribed"

        systemd-run --user --unit=nixwrap-signal --wait --collect ${pkgs.coreutils}/bin/true
        wait_for_log 'member=UnitNew' "$work/allowed"
        wait_for_log 'member=UnitRemoved' "$work/talk"
        sleep 0.2

        # The exact rule and talk both receive UnitNew. talk also receives
        # UnitRemoved; mismatched rules, see and call receive neither signal.
        for mode in allowed talk; do
          [[ $(grep -c member=UnitNew "$work/$mode") -eq 1 ]]
        done
        for mode in member interface path see call; do
          ! grep -q 'interface=org.freedesktop.systemd1.Manager;' "$work/$mode"
        done
      """))

    with subtest("Filtered applications keep stdin and exit status and release their socket"):
      machine.succeed(as_dbus_user("""
        status=0
        printf input | wrap -p -b see:org.freedesktop.systemd1 bash -ec '
          [[ $(cat) == input ]]
          echo "$DBUS_SESSION_BUS_ADDRESS"
          exit 37
        ' >"$work/exited-address" || status=$?
        [[ $status -eq 37 ]]

        # A normal application exit must clean up the proxy too.
        address=$(cat "$work/exited-address")
        [[ $address == unix:path=* ]]
        socket=''${address#unix:path=}
        [[ ! -e ''${socket%/*} ]]
      """))

    with subtest("Invalid D-Bus options fail without running the application"):
      machine.succeed(as_dbus_user("""
        rejected() {
          local output status=0
          output=$(wrap -p "$@" \
            bash -c 'echo PAYLOAD_LAUNCHED >&2; exit 99' 2>&1) || status=$?
          if [[ $status -eq 0 || $output == *PAYLOAD_LAUNCHED* ]]; then
            echo "$output" >&2
            return 1
          fi
        }

        # Raw and filtered access are mutually exclusive, in either order.
        rejected -B -b see:org.freedesktop.systemd1
        rejected -b see:org.freedesktop.systemd1 -B

        # Reject invalid native rules, missing separators and empty arguments.
        rejected -b call:invalid-rule
        for malformed in \
            "" org.freedesktop.systemd1 call broadcast talk own see \
            :rule unknown:rule Call:rule; do
          rejected -b "$malformed"
        done
        for action in call broadcast talk own see; do
          rejected -b "$action:"
        done

        # Opting in must fail closed when no host bus address is available.
        unset DBUS_SESSION_BUS_ADDRESS
        rejected -B
        rejected -b see:org.freedesktop.systemd1
      """))

    with subtest("Store sharing defaults to full access; selected closures exclude other paths"):
      machine.succeed(as_alice("""
        # Positive control: the unrelated store path exists and is visible by default.
        wrap -p ${pkgs.bash}/bin/bash -ec 'test -r ${unsharedPath}'
        export NIX_PROFILES="${unsharedPath}"
        # Select only bash and the data closure; dependencies stay readable,
        # unrelated paths and Nix state stay hidden, and selected paths stay read-only.
        wrap -p -s ${pkgs.bash} -s ${closureRoot} ${pkgs.bash}/bin/bash -ec '
          test -r ${closureRoot}
          test -r ${closureDependency}
          test ! -e ${unsharedPath}
          test ! -e /nix/var/nix
          ! printf changed > ${closureRoot}
        '
        # The declarative launcher must enforce the same closure boundary.
        profile-test-closures -ec '
          test -r ${closureRoot}
          test -r ${closureDependency}
          test ! -e ${unsharedPath}
          test ! -e /nix/var/nix
        '
        # An invalid root must fail rather than launch with incomplete sharing.
        if wrap -p -s /does-not-exist ${pkgs.bash}/bin/bash -c true; then
          echo "Invalid closure root unexpectedly succeeded" >&2
          exit 1
        fi
      """))

    with subtest("Explicit closure bin directories support command lookup in argument order"):
      machine.succeed(as_alice("""
        # Launch by bare name; reversing roots must reverse command precedence.
        test "$(wrap -p -s ${firstCommand} -s ${secondCommand} closure-command)" = first
        test "$(wrap -p -s ${secondCommand} -s ${firstCommand} closure-command)" = second
        # Data-only roots have no bin directory and must not add a PATH entry.
        wrap -p -s ${closureRoot} -s ${pkgs.bash} bash -ec '
          test "$(command -v bash)" = ${pkgs.bash}/bin/bash
          case ":$PATH:" in
            *:${closureRoot}/bin:*) exit 1 ;;
          esac
        '
        # mkWrap automatically includes its package's bin directory as well.
        profile-test-closures -ec 'test "$(command -v bash)" = ${pkgs.bash}/bin/bash'
      """))

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

    with subtest("pasta preserves the caller's numeric identity and user lookup"):
      machine.succeed(as_alice("""
        export EXPECTED_UID="$(id -u)" EXPECTED_GID="$(id -g)"
        for flags in '-n' '-n -u'; do
          wrap $flags -e EXPECTED_UID -e EXPECTED_GID bash -ec '
            test "$UID" = "$EXPECTED_UID"
            test "$(id -u)" = "$EXPECTED_UID"
            test "$(id -g)" = "$EXPECTED_GID"
          '
        done
        test "$(wrap -n -u whoami)" = alice
      """))

    with subtest("removed -m option rejects the launch"):
      machine.succeed(as_alice("""
        marker="$HOME/manual-unsharing-command-ran"
        test ! -e "$marker"
        if wrap -m touch "$marker"; then
          echo 'Unexpected: removed -m option accepted'
          exit 1
        fi
        test ! -e "$marker"
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

    with subtest("-d exposes absolute Wayland paths without prepending XDG_RUNTIME_DIR"):
      machine.succeed(as_alice("""
        export XDG_RUNTIME_DIR=/tmp/wayland-runtime
        export WAYLAND_DISPLAY="/tmp/wayland absolute/wl-0"
        mkdir -p "$XDG_RUNTIME_DIR" "/tmp/wayland absolute"
        echo wayland-display > "$WAYLAND_DISPLAY"
        wrap -d -p bash -c 'cat "$WAYLAND_DISPLAY"' | grep '^wayland-display$'
      """))

    with subtest("-d skips missing Wayland paths"):
      machine.succeed(as_alice("""
        export XDG_RUNTIME_DIR=/tmp/wayland-runtime
        for display in wl-missing "/tmp/wayland absolute/wl-missing"; do
          export WAYLAND_DISPLAY="$display"
          wrap -d -p bash -c '
            case "$WAYLAND_DISPLAY" in
              /*) socket="$WAYLAND_DISPLAY" ;;
              *) socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ;;
            esac
            test ! -e "$socket"
          '
        done
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
        wrap -r "$PWD" bash -ec '
          test "$PWD" = "$HOME/project"
          test -f cwd-marker
          ! touch explicit-readonly-must-win
        '
        test ! -e explicit-readonly-must-win
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

    with subtest("profile symlinks to targets inside and outside a mounted parent stay readable and read-only"):
      machine.succeed(as_alice("""
        mkdir -p /tmp/profile-parent/contained-target /tmp/profile-parent-sibling-target
        echo contained-profile-data > /tmp/profile-parent/contained-target/profile-data
        echo external-profile-data > /tmp/profile-parent-sibling-target/profile-data
        ln -s /tmp/profile-parent/contained-target /tmp/profile-parent/link-to-contained-target
        ln -s /tmp/profile-parent-sibling-target /tmp/profile-parent/link-to-external-target
        NIX_PROFILES="$NIX_PROFILES /tmp/profile-parent /tmp/profile-parent/link-to-contained-target /tmp/profile-parent/link-to-external-target" \
          wrap -p bash -ec '
            test -L /tmp/profile-parent/link-to-contained-target
            test -L /tmp/profile-parent/link-to-external-target
            test "$(cat /tmp/profile-parent/link-to-contained-target/profile-data)" = contained-profile-data
            test "$(cat /tmp/profile-parent/link-to-external-target/profile-data)" = external-profile-data
            ! touch /tmp/profile-parent/link-to-contained-target/write-must-fail
            ! touch /tmp/profile-parent/link-to-external-target/write-must-fail
          '
        test ! -e /tmp/profile-parent/contained-target/write-must-fail
        test ! -e /tmp/profile-parent-sibling-target/write-must-fail
      """))

    with subtest("persistent home preserves host profiles and explicit mounts override profile permissions"):
      machine.succeed(as_alice("""
        export HOME=/tmp/profile-host-home
        mkdir -p "$HOME" /tmp/profile-host-target
        echo host-profile-data > /tmp/profile-host-target/profile-data
        ln -s /tmp/profile-host-target "$HOME/profile-link"
        export NIX_PROFILES="$NIX_PROFILES $HOME/profile-link /tmp/profile-host-target"
        wrap -p -H /tmp/profile-persistent-home bash -ec '
          test "$(cat "$HOME/profile-link/profile-data")" = host-profile-data
          ! touch "$HOME/profile-link/write-must-fail"
          touch "$HOME/persistent-home-marker"
        '
        test -e /tmp/profile-persistent-home/persistent-home-marker
        wrap -p -w /tmp/profile-host-target bash -ec '
          echo explicit-write > /tmp/profile-host-target/explicit-write-marker
        '
        test "$(cat /tmp/profile-host-target/explicit-write-marker)" = explicit-write
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

    with subtest("A custom resolv.conf overrides the default resolver read-only"):
      peer.wait_for_unit("dnsmasq.service")
      # Break the host resolver so success cannot come from the previous DNS
      # configuration (including pasta's default DNS-forwarding upstream).
      machine.succeed("cp -L /etc/resolv.conf /tmp/custom-dns-host-resolv.conf")
      try:
        machine.succeed("printf 'nameserver 192.0.2.53\\n' > /etc/resolv.conf")
        machine.succeed(as_alice("""
          resolver="$(mktemp)"
          trap 'rm -f "$resolver"' EXIT
          printf 'nameserver 192.168.1.3\\n' > "$resolver"

          for mode in -n -N; do
            # Negative control: the default resolver must fail in each mode.
            # dig runs in a fresh process and does not consult an NSS cache.
            if wrap "$mode" dig +short +time=1 +tries=1 network.test A; then
              echo "Unexpected DNS success with the broken host resolver ($mode)" >&2
              exit 1
            fi

            # Raw bwrap arguments follow wrap's generated mounts. Only this
            # custom mount supplies the working resolver used by the query.
            wrap "$mode" -- --ro-bind "$resolver" /etc/resolv.conf bash -euo pipefail -c '
              test "$(cat /etc/resolv.conf)" = "nameserver 192.168.1.3"
              test "$(dig +short +time=2 +tries=1 network.test A)" = 192.168.1.3
              if printf "nameserver 127.0.0.1\\n" > /etc/resolv.conf; then
                echo "Unexpected write access to the custom resolver" >&2
                exit 1
              fi
            '
          done
        """))
      finally:
        # Restore shared guest state even if a control or assertion fails.
        machine.succeed(
          "cat /tmp/custom-dns-host-resolv.conf > /etc/resolv.conf; "
          "rm /tmp/custom-dns-host-resolv.conf"
        )

    with subtest("pasta sandbox uses the caller's hostname with a wrap suffix"):
      machine.succeed(as_alice("""
        expected="$(cat /proc/sys/kernel/hostname)-wrap"
        test "$(wrap -n cat /proc/sys/kernel/hostname)" = "$expected"
      """))

    with subtest("pasta routes sandbox traffic through wrap0"):
      machine.succeed(as_alice("""
        wrap -n ${pkgs.iproute2}/bin/ip route get 192.168.1.3 | grep -F ' dev wrap0 '
      """))

    with subtest("Host socket fixtures respond before sandbox isolation checks"):
      peer.wait_for_unit("nginx.service")
      peer.wait_for_unit("dnsmasq.service")
      peer.wait_for_open_port(8080)
      machine.succeed("systemctl start network-test-host-sockets.service")
      machine.wait_for_open_port(18080)
      host_socket_addresses = (
        "ABSTRACT-CONNECT:wrap-host-abstract "
        "TCP4:127.0.0.1:18080 "
        "'TCP6:[::1]:18080' "
        "TCP4:192.168.1.1:18080 "
        "TCP4:127.0.0.1:18083 "
        "UDP4:127.0.0.1:18081"
      )
      reachable_host_sockets = """
        set -euo pipefail
        for address in """ + host_socket_addresses + """; do
          reply="$(printf host | timeout 2 socat -t 1 -T 1 - "$address" 2>/dev/null || true)"
          [[ "$reply" = host ]] || {
            echo "Host fixture did not respond: $address" >&2
            exit 1
          }
        done
      """
      # Positive controls: all host fixtures must respond before isolation probes.
      machine.wait_until_succeeds(as_alice(
        "bash -s <<'PROBE'\n" + reachable_host_sockets + "\nPROBE"
      ), timeout=15)

    with subtest("-N inherits host sockets and overrides an earlier -n"):
      # Reuse the positive-control probe inside the inherited network namespace.
      for flags in ["-N", "-n -N"]:
        machine.succeed(as_alice(
          "wrap " + flags + " bash -s <<'PROBE'\n" + reachable_host_sockets + "\nPROBE"
        ))

    with subtest("-n isolates host sockets and overrides an earlier -N"):
      # A failed connection is expected; only a host echo indicates a leak.

      blocked_host_sockets = """
        set -euo pipefail
        for address in """ + host_socket_addresses + """; do
          reply="$(printf host | timeout 2 socat -t 1 -T 1 - "$address" 2>/dev/null || true)"
          [[ -z "$reply" ]] || {
            echo "Unexpected host response: $address: $reply" >&2
            exit 1
          }
        done
      """
      # Repeating -n must not accidentally enable pasta's automatic forwarding.
      for flags in ["-n", "-n -n", "-N -n"]:
        machine.succeed(as_alice(
          "wrap " + flags + " bash -s <<'PROBE'\n" + blocked_host_sockets + "\nPROBE"
        ))

    with subtest("Both network modes support outbound TCP and DNS"):
      machine.succeed(as_alice("""
        for flags in '-n' '-n -n' '-N' '-n -N' '-N -n'; do
          wrap $flags bash -euo pipefail -c '
            test "$(dig +short +time=2 +tries=1 network.test A)" = 192.168.1.3
            test "$(curl --noproxy "*" --fail --silent --show-error --max-time 5 \
              http://network.test:8080)" = outbound-network-ok
          '
        done

        # With no network option, even a numeric address must remain unreachable.
        if wrap curl --noproxy "*" --fail --silent --show-error --max-time 2 \
          http://192.168.1.3:8080; then
          echo 'Unexpected outbound network access without -n' >&2
          exit 1
        fi
      """))

    with subtest("Nested -N shares the outer sandbox's loopback"):
      machine.succeed(as_alice("""
        wrap -n bash -euo pipefail -c '
          # The server lives in the outer pasta namespace, not on the host.
          socat TCP4-LISTEN:18082,bind=127.0.0.1,reuseaddr,fork EXEC:cat &
          server=$!
          trap "kill $server" EXIT
          # The listener starts asynchronously; retry only until it is ready.
          for attempt in {1..30}; do
            reply="$(printf nested | wrap -N socat -T 1 - TCP4:127.0.0.1:18082 || true)"
            if [[ "$reply" = nested ]]; then
              exit 0
            fi
            sleep 0.1
          done
          echo "Inner -N sandbox could not reach the outer loopback server" >&2
          exit 1
        '
      """))

    with subtest("CLI and mkWrap expose only the explicitly allowed host TCP port"):
      machine.succeed(as_alice("""
        # Exercise CLI flags and the generated mkWrap launcher against the same
        # allowlist contract.
        check_host_port_access() {
          "$@" -euo pipefail -c '
            # The selected port forwards to the host service, not a sandbox server.
            reply="$(printf allowed | socat -T 1 - TCP4:127.0.0.1:18080)"
            test "$reply" = allowed
            # An existing but unlisted TCP listener must remain unreachable.
            if timeout 2 socat -T 1 - TCP4:127.0.0.1:18083 </dev/null; then
              echo "Unexpected access to an unlisted host port" >&2
              exit 1
            fi
            # A TCP exception must not expose the host UDP listener.
            reply="$(printf blocked | socat -t 1 -T 1 - UDP4:127.0.0.1:18081 || true)"
            test -z "$reply"
          '
        }
        check_host_port_access wrap -n -P 18080 bash
        check_host_port_access profile-test-host-ports
      """))

    with subtest("Repeated -P options allow both selected host TCP ports"):
      machine.succeed(as_alice("""
        wrap -n -P 18080 -P 18083 bash -euo pipefail -c '
          for port in 18080 18083; do
            reply="$(printf repeated | socat -T 1 - TCP4:127.0.0.1:$port)"
            test "$reply" = repeated
          done
        '
      """))

    with subtest("-P rejects invalid ports and non-pasta network modes"):
      machine.succeed(as_alice("""
        # Reject out-of-range numbers and pasta's broader forwarding syntax:
        # the CLI accepts individual ports, never ranges, lists, or auto mode.
        for port in 0 65536 -1 auto 80,81; do
          if wrap -n -P "$port" true; then
            echo "Unexpected acceptance of invalid host port: $port" >&2
            exit 1
          fi
        done
        # Port exceptions are meaningful only in the isolated pasta mode.
        ! wrap -P 18080 true
        ! wrap -N -P 18080 true
      """))

    machine.succeed("systemctl stop network-test-host-sockets.service")

    # WireGuard models a VPN selected with -I while ordinary LAN access remains
    # available. Verify that sandbox traffic uses the VPN, never silently falling
    # back to the LAN when an address family is unavailable or the VPN goes down.
    # Two paths reach the same peer:
    #   LAN: machine eth1 192.168.1.1 / 2001:db8:1::1 -> peer .3 / ::3
    #   VPN: machine wg1  10.77.0.1 / fd77::1         -> peer .2 / ::2
    # Lower-metric LAN routes deliberately win without -I. Merely reaching the
    # peer is not proof of binding: /source must report the VPN source address.
    # Root sets up the tunnel; all wrap probes run as unprivileged alice.
    # The shared fixture progresses from IPv4-only to dual-stack to IPv6-only,
    # then down, so each phase below depends on the preceding configuration.
    with subtest("-I binds unprivileged outbound traffic to WireGuard without fallback"):
      machine.succeed("umask 077; wg genkey > /tmp/wrap-wg.key")
      peer.succeed("umask 077; wg genkey > /tmp/wrap-wg.key")
      machine_key = machine.succeed("wg pubkey < /tmp/wrap-wg.key").strip()
      peer_key = peer.succeed("wg pubkey < /tmp/wrap-wg.key").strip()

      # Start with /32 addresses and no default route on wg1, like a split VPN.
      machine.succeed(
        "ip link add wg1 type wireguard; "
        "ip address add 10.77.0.1/32 dev wg1; "
        f"wg set wg1 private-key /tmp/wrap-wg.key listen-port 51820 peer {peer_key} "
        "endpoint 192.168.1.3:51820 allowed-ips 10.77.0.2/32; "
        "ip link set wg1 up; "
        "ip route add 10.77.0.2/32 dev wg1 metric 100; "
        "ip route add 10.77.0.2/32 via 192.168.1.3 dev eth1 metric 10"
      )
      peer.succeed(
        "ip link add wg1 type wireguard; "
        "ip address add 10.77.0.2/32 dev wg1; "
        f"wg set wg1 private-key /tmp/wrap-wg.key listen-port 51820 peer {machine_key} "
        "endpoint 192.168.1.1:51820 allowed-ips 10.77.0.1/32; "
        "ip link set wg1 up; "
        "ip route add 10.77.0.1/32 dev wg1"
      )
      peer.wait_for_unit("network-test-udp.service")

      # pasta forwards sandbox DNS to the host's configured resolver. Point it
      # at the VPN peer so DNS probes also exercise the selected interface.
      machine.succeed(
        "cp -L /etc/resolv.conf /tmp/wrap-host-resolv.conf; "
        "printf 'nameserver 10.77.0.2\\n' > /etc/resolv.conf"
      )
      try:
        with subtest("IPv4-only -I selects VPN egress regardless of -n option order"):
          machine.succeed(as_alice("""
            # Positive control: ordinary -n reaches the VPN IP over the LAN.
            test "$(wrap -n curl --noproxy "*" -fsS --max-time 3 \
              http://10.77.0.2:8080/source)" = 192.168.1.1

            # -I implies -n, survives a later -n, and the last -I wins.
            # Intentional word splitting turns each flags string into arguments.
            for flags in '-I wg1' '-n -I wg1' '-I wg1 -n' '-I missing-wrap0 -I wg1'; do
              test "$(wrap $flags curl --noproxy "*" -fsS --max-time 3 \
                http://10.77.0.2:8080/source)" = 10.77.0.1
            done
          """))

        with subtest("IPv4-only -I supports DNS, UDP, and the sandbox route"):
          machine.succeed(as_alice("""
            wrap -I wg1 bash -euo pipefail -c '
              test "$(dig +short +time=2 +tries=1 wg.test A)" = 10.77.0.2
              test "$(printf vpn-udp | timeout 3 socat -t 1 -T 1 - \
                UDP4:10.77.0.2:18082)" = vpn-udp
            '
            # The sandbox sees pasta's wrap0, not the host WireGuard device.
            wrap -I wg1 ${pkgs.iproute2}/bin/ip route get 10.77.0.2 | grep -F ' dev wrap0 '
          """))

        with subtest("IPv4-only -I cannot fall back to the host IPv6 connection"):
          machine.succeed(as_alice("""
            # A working LAN IPv6 control makes failure meaningful.
            test "$(wrap -n curl --noproxy "*" -g -6 -fsS --max-time 3 \
              http://[2001:db8:1::3]:8080/source)" = 2001:db8:1::1
            if wrap -I wg1 curl --noproxy "*" -g -6 -fsS --max-time 3 \
              http://[2001:db8:1::3]:8080/source; then
              echo 'Unexpected IPv6 fallback from IPv4-only interface' >&2
              exit 1
            fi
          """))

        with subtest("-I rejects missing and empty interfaces before launching the command"):
          machine.succeed(as_alice("""
            for interface in missing-wrap0 ""; do
              # A failed exit alone would not prove that the payload never ran.
              marker="$HOME/invalid-interface-command-ran"
              test ! -e "$marker"
              if wrap -I "$interface" touch "$marker"; then
                echo 'Unexpected launch with an invalid outbound interface' >&2
                exit 1
              fi
              test ! -e "$marker"
            done
          """))

        with subtest("Dual-stack -I uses VPN source addresses for both families"):
          # Add /128 IPv6 addresses without link-local addresses, as on a
          # typical WireGuard device. Keep preferring the LAN route without -I.
          machine.succeed(
            "ip -6 address add fd77::1/128 dev wg1 nodad; "
            f"wg set wg1 peer {peer_key} allowed-ips 10.77.0.2/32,fd77::2/128; "
            "ip -6 route add fd77::2/128 dev wg1 metric 100; "
            "ip -6 route add fd77::2/128 via 2001:db8:1::3 dev eth1 metric 10"
          )
          peer.succeed(
            "ip -6 address add fd77::2/128 dev wg1 nodad; "
            f"wg set wg1 peer {machine_key} allowed-ips 10.77.0.1/32,fd77::1/128; "
            "ip -6 route add fd77::1/128 dev wg1"
          )
          peer.wait_for_unit("network-test-udp6.service")
          machine.succeed(as_alice("""
            test "$(wrap -n curl --noproxy "*" -g -6 -fsS --max-time 3 \
              http://[fd77::2]:8080/source)" = 2001:db8:1::1
            test "$(wrap -I wg1 curl --noproxy "*" -g -6 -fsS --max-time 3 \
              http://[fd77::2]:8080/source)" = fd77::1
            test "$(wrap -I wg1 curl --noproxy "*" -fsS --max-time 3 \
              http://10.77.0.2:8080/source)" = 10.77.0.1
            wrap -I wg1 bash -euo pipefail -c '
              test "$(printf vpn-udp6 | timeout 3 socat -t 1 -T 1 - \
                UDP6:[fd77::2]:18082)" = vpn-udp6
            '
          """))

        with subtest("IPv6-only -I retains DNS and TCP without host IPv4 fallback"):
          # Remove only the client's VPN IPv4 address; the LAN remains usable.
          machine.succeed(
            "ip -4 address del 10.77.0.1/32 dev wg1; "
            "printf 'nameserver fd77::2\\n' > /etc/resolv.conf"
          )
          machine.succeed(as_alice("""
            wrap -I wg1 bash -euo pipefail -c '
              # An A record can be resolved over an IPv6 DNS transport.
              test "$(dig +short +time=2 +tries=1 wg.test A)" = 10.77.0.2
              test "$(curl --noproxy "*" -g -6 -fsS --max-time 3 \
                http://[fd77::2]:8080/source)" = fd77::1
            '
            if wrap -I wg1 curl --noproxy "*" -4 -fsS --max-time 3 \
              http://192.168.1.3:8080; then
              echo 'Unexpected IPv4 fallback from IPv6-only interface' >&2
              exit 1
            fi
          """))

        with subtest("A down VPN cannot fall back to the still-working LAN"):
          machine.succeed("ip link set wg1 down")
          machine.succeed(as_alice("""
            test "$(wrap -n curl --noproxy "*" -fsS --max-time 3 \
              http://10.77.0.2:8080/source)" = 192.168.1.1
            if wrap -I wg1 curl --noproxy "*" -fsS --max-time 3 \
              http://10.77.0.2:8080/source; then
              echo 'Unexpected fallback from down WireGuard interface' >&2
              exit 1
            fi
          """))
      finally:
        # Restore the shared host resolver and remove the runtime VPN fixture.
        machine.succeed(
          "cat /tmp/wrap-host-resolv.conf > /etc/resolv.conf; "
          "ip link del wg1; "
          "rm /tmp/wrap-wg.key /tmp/wrap-host-resolv.conf"
        )
        peer.succeed("ip link del wg1; rm /tmp/wrap-wg.key")

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

    with subtest("dev.tty.legacy_tiocsti=0 allows wrap without --new-session"):
      machine.succeed("""
        set -euo pipefail
        cat /proc/sys/dev/tty/legacy_tiocsti | grep '^0$' ||
          (echo 'Unexpected: legacy_tiocsti is not 0'; false)
        wrap bash -c 'echo ok' | grep '^ok$' ||
          (echo 'Unexpected: wrap failed when legacy_tiocsti is 0'; false)
      """)

    with subtest("dev.tty.legacy_tiocsti=1 requires --new-session"):
      machine_tiocsti.succeed("""
        set -euo pipefail
        cat /proc/sys/dev/tty/legacy_tiocsti | grep '^1$' ||
          (echo 'Unexpected: legacy_tiocsti is not 1'; false)

        # Without --new-session, wrap should fail
        if wrap bash -c 'true' 2>/dev/null; then
          echo 'Unexpected: wrap succeeded without --new-session when legacy_tiocsti is 1'
          false
        fi

        # Error message should mention --new-session
        ERR=$(wrap bash -c 'true' 2>&1 || true)
        echo "$ERR" | grep -q -- '--new-session' ||
          (echo 'Unexpected: error message does not mention --new-session'; false)
      """)

    with subtest("dev.tty.legacy_tiocsti=1 allows wrap with --new-session"):
      machine_tiocsti.succeed(as_alice("""
        wrap -- --new-session bash -c 'echo ok' | grep '^ok$' ||
          (echo 'Unexpected: wrap failed with --new-session when legacy_tiocsti is 1'; false)
      """))
  '';
}
