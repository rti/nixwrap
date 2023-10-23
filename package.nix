{ stdenvNoCC, makeWrapper, lib, path }:

stdenvNoCC.mkDerivation rec {
  name = "wrap";
  src = ./.;

  installPhase = ''
    mkdir -p $out/bin
    cp -r wrap.sh $out/bin/wrap
  '';

  meta = with lib; {
    description = "Easy application sandbox";
    homepage = "https://github.com/rti/nixwrap";
    license = licenses.mit;
    maintainers = with maintainers; [ rti ];
    platforms = platforms.linux;
  };
}
