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
        exec ${pkgs.lib.getExe wrapPkg} ${wrapArgs} ${package}/bin/${executable} "\$@"
        _EOF
        chmod a+x $out/bin/${executable}
      '';
    };
}
