{
  stdenvNoCC,
  pkgs,
  lib,
  bubblewrap,
  makeWrapper,
}:

stdenvNoCC.mkDerivation {
  name = "wrap";
  src = ./.;

  nativeInputs = [ bubblewrap ];

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp -r wrap.sh $out/bin/wrap

    wrapProgram $out/bin/wrap \
        --prefix PATH : ${lib.makeBinPath [ pkgs.bubblewrap ]} 
  '';

  meta = with lib; {
    description = "Easy application sandboxing";
    homepage = "https://github.com/rti/nixwrap";
    license = licenses.mit;
    maintainers = with maintainers; [ rti ];
    platforms = platforms.linux;
  };
}
