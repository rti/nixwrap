{ pkgs, wrapPkg, ... }:
{
  wrap =
    {
      package,
      wrapArgs ? "",
      executable ? package.pname,
    }:
    pkgs.symlinkJoin {
      name = package.name;
      paths = [ package ];
      postBuild = ''
        mv $out/bin/${executable}{,-nowrap}
        cat << _EOF > $out/bin/${executable}
        #!/usr/bin/env bash
        exec ${pkgs.lib.getExe wrapPkg} ${wrapArgs} ${package}/bin/${executable} "\$@"
        _EOF
        chmod a+x $out/bin/${executable}
      '';
    };

  mkWrap =
    {
      name,
      package,
      executable ? package.pname,
      arguments ? [ ],
      home ? null,
      shareCwd ? false,
      hostPorts ? [ ],
      closures ? null,
      mounts ? {
        writable = [ ];
        readOnly = [ ];
      },
      capabilities ? { },
      dbus ? { },
      egress ? { tcp = [ ]; udp = [ ]; },
      environment ? { },
    }:
    let
      escapePath =
        path:
        let
          value = toString path;
        in
        if pkgs.lib.hasPrefix "~/" value then
          ''"$HOME"/${pkgs.lib.escapeShellArg (pkgs.lib.removePrefix "~/" value)}''
        else
          pkgs.lib.escapeShellArg value;
      capabilityFlags = {
        desktop = "-d";
        network = "-n";
        hostNetwork = "-N";
        audio = "-a";
        camera = "-c";
        hostDbus = "-B";
        userInfo = "-u";
      };
      enabledCapabilities = builtins.filter (
        capability:
        (capabilities.${capability} or false)
        && (capability != "network" || !(capabilities.hostNetwork or false))
      ) (builtins.attrNames capabilityFlags);
      wrapArguments =
        (map (path: "-w ${escapePath path}") (mounts.writable or [ ]))
        ++ (map (path: "-r ${escapePath path}") (mounts.readOnly or [ ]))
        ++ pkgs.lib.optionals (closures != null) (
          map (path: "-s ${pkgs.lib.escapeShellArg (toString path)}") ([ package ] ++ closures)
        )
        ++ (map (capability: capabilityFlags.${capability}) enabledCapabilities)
        ++ (map (rule: "-b ${pkgs.lib.escapeShellArg "call:${rule}"}") (dbus.call or [ ]))
        ++ (map (rule: "-b ${pkgs.lib.escapeShellArg "broadcast:${rule}"}") (dbus.broadcast or [ ]))
        ++ (map (name: "-b ${pkgs.lib.escapeShellArg "talk:${name}"}") (dbus.talk or [ ]))
        ++ (map (name: "-b ${pkgs.lib.escapeShellArg "own:${name}"}") (dbus.own or [ ]))
        ++ (map (name: "-b ${pkgs.lib.escapeShellArg "see:${name}"}") (dbus.see or [ ]))
        ++ (map (port: "-P ${toString port}") hostPorts)
        ++ (map (endpoint: "--allowed-egress-tcp ${pkgs.lib.escapeShellArg (toString endpoint)}") (egress.tcp or [ ]))
        ++ (map (endpoint: "--allowed-egress-udp ${pkgs.lib.escapeShellArg (toString endpoint)}") (egress.udp or [ ]))
        ++ (map (key: "-e ${pkgs.lib.escapeShellArg key}") (builtins.attrNames environment))
        ++ pkgs.lib.optional (!shareCwd) "-p"
        ++ pkgs.lib.optional (home != null) "-H ${escapePath home}";
      environmentSetup = builtins.concatStringsSep "\n" (
        map (key: "export ${key}=${pkgs.lib.escapeShellArg (toString environment.${key})}") (
          builtins.filter (key: environment.${key} != null) (builtins.attrNames environment)
        )
      );
      command = pkgs.lib.escapeShellArgs ([ "${package}/bin/${executable}" ] ++ arguments);
    in
    assert builtins.all (port: builtins.isInt port && port >= 1 && port <= 65535) hostPorts;
    assert hostPorts == [ ] || (
      (capabilities.network or false) && !(capabilities.hostNetwork or false)
    );
    assert builtins.all (capability: builtins.hasAttr capability capabilityFlags) (
      builtins.attrNames capabilities
    );
    assert !(builtins.hasAttr "HOME" environment);
    assert builtins.all (key: builtins.elem key [ "call" "broadcast" "talk" "own" "see" ]) (
      builtins.attrNames dbus
    );
    assert !(capabilities.hostDbus or false) || builtins.all (rules: rules == [ ]) (
      builtins.attrValues dbus
    );
    assert builtins.all (key: builtins.elem key [ "tcp" "udp" ]) (
      builtins.attrNames egress
    );
    # Egress tunnels need a network namespace of their own; hostNetwork keeps
    # the caller's, where wrap cannot address the session's loopback.
    assert !(capabilities.hostNetwork or false) || (egress.tcp == [ ] && egress.udp == [ ]);
    assert builtins.all (key: builtins.match "[A-Za-z_][A-Za-z0-9_]*" key != null) (
      builtins.attrNames environment
    );
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      ${environmentSetup}
      exec ${pkgs.lib.getExe wrapPkg} ${builtins.concatStringsSep " " wrapArguments} ${command} "$@"
    '';
}
