{ pkgs ? import <nixpkgs> { }, ... }:

{
  wrap =
    { package
    , wrapArgs ? ""
    , executable ? package.pname
    }:

    pkgs.symlinkJoin {
      name = package.name;
      paths = [ package ];
      postBuild = ''
        mv $out/bin/${executable}{,-nowrap}
        cat << _EOF > $out/bin/${executable}
          exec ${./wrap.sh} ${wrapArgs} ${package}/bin/${executable} "\$@"
        _EOF
        chmod a+x $out/bin/${executable}
      '';
    };

  # wrap = prog:
  #   prog.overrideAttrs (oldAttrs:
  #     let
  #       name = prog.pname;
  #     in
  #     {
  #       # TODO: why do we need to use postInstall? why is installPhase $out wrong?
  #       postInstall = oldAttrs.postInstall or "" + ''
  #         mv $out/bin/${name} $out/bin/${name}-nowrap
  #         cat << _EOF > $out/bin/${name}
  #         #! ${super.runtimeShell} -e
  #         exec ${./wrap.sh} \
  #           -- \
  #           ${name}-nowrap "\$@"
  #         _EOF
  #         chmod 0755 $out/bin/${name}
  #       '';
  #     });
  #
}
