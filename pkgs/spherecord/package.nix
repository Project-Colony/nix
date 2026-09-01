{
  lib,
  stdenv,
  appimageTools,
  fetchurl,
  writeText,
  sources,
}:

let
  pname = "spherecord";
  inherit (sources.spherecord) version;
  inherit (stdenv.hostPlatform) system;

  hash =
    sources.spherecord.hashes.${system}
      or (throw "spherecord: no AppImage is published for ${system}");

  # SphereCord publishes one AppImage per arch, the x86_64 one unsuffixed.
  suffix = if system == "aarch64-linux" then "-arm64" else "";

  src = fetchurl {
    url = "https://github.com/Project-Colony/SphereCord/releases/download/v${version}/SphereCord-${version}${suffix}.AppImage";
    inherit hash;
  };

  # Only used to lift the icons out. The desktop entry is written from the file
  # SphereCord keeps in its own repo (build/gg.spherecord.app.desktop) rather
  # than scraped out of the image, so a change in how electron-builder writes
  # its internal copy cannot silently produce a broken Exec line.
  extracted = appimageTools.extract { inherit pname version src; };

  # Upstream's own template declares `Icon=gg.spherecord.app`, which is correct
  # for electron-builder's installers because they rename the icon files as they
  # install them. The AppImage does not: its icons are hicolor/*/apps/spherecord.png.
  # Copying the template verbatim therefore yields a launcher entry with no icon.
  desktopEntry = writeText "gg.spherecord.app.desktop" ''
    [Desktop Entry]
    Name=SphereCord
    GenericName=Internet Messenger
    Type=Application
    Exec=spherecord %U
    Icon=spherecord
    Categories=Network;InstantMessaging;Chat;
    Keywords=discord;vencord;electron;chat;spherecord;
    MimeType=x-scheme-handler/discord;
    StartupWMClass=spherecord
  '';
in
appimageTools.wrapType2 {
  inherit pname version src;

  # @vencord/venmic is an optional native module that carries audio during a
  # screenshare. Without pipewire inside the FHS environment it fails at dlopen
  # and screenshare loses sound with no visible error.
  extraPkgs = pkgs: [ pkgs.pipewire ];

  extraInstallCommands = ''
    install -Dm444 ${desktopEntry} $out/share/applications/gg.spherecord.app.desktop

    # Icons sit at usr/share/icons/hicolor/<size>/apps inside the image. Copy
    # them defensively: a layout change upstream should cost the launcher icon,
    # not fail the build.
    if [ -d ${extracted}/usr/share/icons ]; then
      mkdir -p $out/share
      cp -r ${extracted}/usr/share/icons $out/share/
    fi
  '';

  meta = {
    description = "Discord desktop app with Equicord preinstalled, Project Colony build";
    homepage = "https://github.com/Project-Colony/SphereCord";
    license = lib.licenses.gpl3Plus;
    mainProgram = "spherecord";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
