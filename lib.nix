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
      mounts ? { writable = [ ]; readOnly = [ ]; },
      capabilities ? { },
      environment ? { },
    }:
    let
      escapePath = path:
        let value = toString path;
        in if pkgs.lib.hasPrefix "~/" value then
          ''"$HOME"/${pkgs.lib.escapeShellArg (pkgs.lib.removePrefix "~/" value)}''
        else
          pkgs.lib.escapeShellArg value;
      capabilityFlags = {
        desktop = "-d";
        network = "-n";
        audio = "-a";
        camera = "-c";
        dbus = "-b";
        userInfo = "-u";
      };
      enabledCapabilities = builtins.filter
        (capability: capabilities.${capability} or false)
        (builtins.attrNames capabilityFlags);
      wrapArguments =
        (map (path: "-w ${escapePath path}") (mounts.writable or [ ]))
        ++ (map (path: "-r ${escapePath path}") (mounts.readOnly or [ ]))
        ++ (map (capability: capabilityFlags.${capability}) enabledCapabilities)
        ++ (map (key: "-e ${pkgs.lib.escapeShellArg key}") (builtins.attrNames environment))
        ++ pkgs.lib.optional (!shareCwd) "-p"
        ++ pkgs.lib.optional (home != null) "-H ${escapePath home}";
      environmentSetup = builtins.concatStringsSep "\n" (
        map (key: "export ${key}=${pkgs.lib.escapeShellArg (toString environment.${key})}")
          (builtins.filter (key: environment.${key} != null) (builtins.attrNames environment))
      );
      command = pkgs.lib.escapeShellArgs ([ "${package}/bin/${executable}" ] ++ arguments);
    in
    assert builtins.all (capability: builtins.hasAttr capability capabilityFlags)
      (builtins.attrNames capabilities);
    assert !(builtins.hasAttr "HOME" environment);
    assert builtins.all
      (key: builtins.match "[A-Za-z_][A-Za-z0-9_]*" key != null)
      (builtins.attrNames environment);
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      ${environmentSetup}
      exec ${pkgs.lib.getExe wrapPkg} ${builtins.concatStringsSep " " wrapArguments} ${command} "$@"
    '';
}
