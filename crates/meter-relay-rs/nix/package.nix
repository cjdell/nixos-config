{
  lib,
  craneLib,
  pkg-config,
  makeWrapper,
  udev,
  buildNpmPackage,
  importNpmLock,

  # Reuse an already-built crane dependency artifact directory instead of
  # compiling the crates.io dependency graph from scratch (the service module
  # passes nothing, so crane builds it here).
  cargoArtifacts ? null,
}:

let
  # Build the Solid.js dashboard first; the Rust binary serves it from
  # $MR_WEB_DIR, which the wrapper below points at this output.
  web = buildNpmPackage {
    pname = "meter-relay-web";
    version = "0.1.0";

    src = lib.cleanSourceWith {
      src = ../web;
      filter =
        path: _type:
        let
          base = baseNameOf (toString path);
        in
        base != "node_modules" && base != "dist";
    };

    npmDeps = importNpmLock { npmRoot = ../web; };
    npmConfigHook = importNpmLock.npmConfigHook;
    npmBuildScript = "build";

    installPhase = ''
      runHook preInstall
      mkdir -p $out/dist
      cp -r dist/. $out/dist/
      runHook postInstall
    '';
  };

  # Only keep what cargo actually reads (Cargo.toml/Cargo.lock, *.rs,
  # .cargo/config.toml). Editing the dashboard, the Nix files, or the README
  # therefore leaves the dependency artifacts below untouched.
  src = craneLib.cleanCargoSource ../.;

  commonArgs = {
    pname = "meter-relay";
    version = "0.1.0";
    inherit src;

    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ udev ];
  };

  # Compile the dependency graph (including dev-dependencies) once, keyed only
  # on the cargo inputs. `buildPackage` below then only rebuilds this crate.
  cargoArtifacts' =
    if cargoArtifacts != null then cargoArtifacts else craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (
  commonArgs
  // {
    cargoArtifacts = cargoArtifacts';

    nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ makeWrapper ];

    postInstall = ''
      wrapProgram $out/bin/meter-relay \
        --set MR_WEB_DIR ${web}/dist
    '';

    meta = with lib; {
      description = "Share one grid meter between a Solis and a Solax inverter, with a live web dashboard";
      homepage = "https://github.com/cjdell/meter-relay";
      mainProgram = "meter-relay";
      platforms = platforms.linux;
    };
  }
)
