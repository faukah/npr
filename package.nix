{
  lib,
  rustPlatform,
  rev ? "dirty",
}:
let
  cargoToml = lib.importTOML ./Cargo.toml;
  fs = lib.fileset;
in
rustPlatform.buildRustPackage {
  pname = "npr";
  version = "${cargoToml.package.version}-${rev}";

  src = fs.toSource {
    root = ./.;

    fileset = fs.intersection (fs.fromSource (lib.sources.cleanSource ./.)) (
      fs.unions [
        ./src
        ./Cargo.toml
        ./Cargo.lock
      ]
    );
  };

  cargoLock.lockFile = ./Cargo.lock;
}
